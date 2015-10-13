require 'timeout'

module Houston
  APPLE_PRODUCTION_GATEWAY_URI = "apn://gateway.push.apple.com:2195"
  APPLE_PRODUCTION_FEEDBACK_URI = "apn://feedback.push.apple.com:2196"

  APPLE_DEVELOPMENT_GATEWAY_URI = "apn://gateway.sandbox.push.apple.com:2195"
  APPLE_DEVELOPMENT_FEEDBACK_URI = "apn://feedback.sandbox.push.apple.com:2196"

  class Client
    attr_accessor :gateway_uri, :feedback_uri, :certificate, :passphrase, :timeout
    attr_reader :logger

    class << self
      def development
        client = self.new
        client.gateway_uri = APPLE_DEVELOPMENT_GATEWAY_URI
        client.feedback_uri = APPLE_DEVELOPMENT_FEEDBACK_URI
        client
      end

      def production
        client = self.new
        client.gateway_uri = APPLE_PRODUCTION_GATEWAY_URI
        client.feedback_uri = APPLE_PRODUCTION_FEEDBACK_URI
        client
      end

      def mock
        client = self.new
        client.gateway_uri = "apn://127.0.0.1:2195"
        client.feedback_uri = nil
        client
      end
    end

    #registers exception handler. upon uncaught exceptions the block will be called with exception object as argument
    def capture_exceptions &block
      @exception_handler = block
    end

    def initialize
      @gateway_uri = ENV['APN_GATEWAY_URI']
      @feedback_uri = ENV['APN_FEEDBACK_URI']
      @certificate = File.read(ENV['APN_CERTIFICATE']) if ENV['APN_CERTIFICATE']
      @certificate_for_log = @certificate.split(//).last(65).join if @certificate
      @passphrase = ENV['APN_CERTIFICATE_PASSPHRASE']
      @timeout = Float(ENV['APN_TIMEOUT'] || 0.5)
      @pid = Process.pid
      @connections_queue = Queue.new
      @connection_threads = []
      @measures = {}
    end

    def measure type
      t = Time.now
      yield
    ensure
      @measures[type] = (@measures[type] || 0) + (Time.now - t) #measure even if crushed
    end

    def push(notifications, packet_size: 10)
      @logger = BackgroundLogger.new 'log/houston_test', :daily
      failed_notifications = []

      beginning = Time.now

      5.times{ add_connection }
      logger.info("Connections creation took: #{Time.now - beginning}")

      beginning = Time.now
      notifications.each_with_index{|notification, index| notification.id = index}

      sent_count = 0
      while !notifications.empty?
        local_start_index = sent_count
        logger.info("Get connection, starting at index: #{notifications[0].id}")
        connection = measure(:get_connection){ get_connection }

        last_sent_id = nil
        write_thread = Thread.new(connection, notifications) do |connection, notifications|
          begin
            notifications.each_slice(packet_size) do |group|
              last_sent_id = group[-1].id
              write_notifications(connection, group)

              sent_count += group.size
              yield sent_count
            end
          rescue Errno::EPIPE => e
            logger.warn "Broken pipe on write, last sent id: #{last_sent_id}"
          rescue => e
            log_exception!(e, "write") #swallow any unexpected exceptions
          end

          connection.socket.close_write #should send EOF to server making it send EOF back
          logger.info("End of write, closed socket for writing")
        end

        error_id = error_id_from_read = read_errors(connection)
        puts "--- Got error on #{error_id}"
        write_thread.kill
        connection.close

        #custom error or connection closed before finishing all writes
        if error_id.is_a?(Exception) || (!error_id && last_sent_id != notifications[-1].id)
          error_id = last_sent_id || notifications[0].id
        end

        break if !error_id

        error_index = notifications.index{|n| n.id == error_id }
        if !error_index
          logger.warn "Invalid error notification id: #{error_id}"
          break if last_sent_id == notifications[-1].id
          error_id = last_sent_id
          error_index = notifications.index{|n| n.id == error_id }
        end

        error_notification = notifications[error_index]
        failed_notifications << error_notification if error_id == error_id_from_read #check that id was received from server

        logger.info "Error index #{error_index}/#{notifications.size}, token '#{error_notification.token}'"

        sent_count = local_start_index + error_index + 1
        yield sent_count
        notifications.shift(error_index + 1)
      end

      logger.info("Finished after #{Time.now - beginning}")
      logger.info("Measures: #{@measures.to_json}")

      failed_notifications
    ensure
      threads, @connection_threads = @connection_threads, []
      threads.each{|t| t.join(5) || t.kill } #allow started connections to finish opening, but if time passes, kill anyway
      @connections_queue.pop.close while !@connections_queue.empty? #clean whole pool
      @logger.close
    end

    def add_connection
      connection = Connection.new(@gateway_uri, @certificate, @passphrase)
      connection.open
      @connections_queue << connection
    rescue => e
      log_exception! e, "add_connection"
      sleep 1
      retry
    end

    def get_connection
      @connection_threads << Thread.new{ add_connection }
      Timeout.timeout(10){ @connections_queue.pop } #blocking if empty, timeout in case all threads are dead or connection stuck while opening
    end

    def log_exception!(e, where)
      @exception_handler.call(e) if @exception_handler
      logger.error "* #{e.class.name} on #{where}: #{e.message}\n" + e.backtrace[0,5].join("\n")
      nil
    end

    def write_notifications(connection, notifications)
      messages = notifications.map do |noti|
        begin
          measure(:message){noti.message}
        rescue => e
          log_exception!(e, "create notification message")
        end
      end

      request = messages.compact.join
      measure(:write){connection.write(request)}
    end

    def read_errors(connection)
      error = connection.read(6) #returns nil on EOF at start
      return nil if !error #ok

      command, error_code, error_noti_id = error.unpack("ccN")
      logger.warn "Error on id #{error_noti_id}, code: #{error_code}"
      error_noti_id
    rescue => e #TODO: create statistics of errors, maybe should be different handling of different types
      log_exception!(e, "read")
      e
    end

    def unregistered_devices
      devices = []

      Connection.open(@feedback_uri, @certificate, @passphrase) do |connection|
        while line = connection.read(38)
          feedback = line.unpack('N1n1H140')
          timestamp = feedback[0]
          token = feedback[2].scan(/.{0,8}/).join(' ').strip
          devices << {token: token, timestamp: timestamp} if token && timestamp
        end
      end

      devices
    end

    def devices
      unregistered_devices.collect{|device| device[:token]}
    end
  end
end
