require 'logger'

module Houston
  APPLE_PRODUCTION_GATEWAY_URI = "apn://gateway.push.apple.com:2195"
  APPLE_PRODUCTION_FEEDBACK_URI = "apn://feedback.push.apple.com:2196"

  APPLE_DEVELOPMENT_GATEWAY_URI = "apn://gateway.sandbox.push.apple.com:2195"
  APPLE_DEVELOPMENT_FEEDBACK_URI = "apn://feedback.sandbox.push.apple.com:2196"

  class Client
    attr_accessor :gateway_uri, :feedback_uri, :certificate, :passphrase, :timeout

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
    end

    def initialize
      @gateway_uri = ENV['APN_GATEWAY_URI']
      @feedback_uri = ENV['APN_FEEDBACK_URI']
      @certificate = File.read(ENV['APN_CERTIFICATE']) if ENV['APN_CERTIFICATE']
      @passphrase = ENV['APN_CERTIFICATE_PASSPHRASE']
      @timeout = Float(ENV['APN_TIMEOUT'] || 0.5)
    end

    def push(*notifications, &update_block)
      @mutex = Mutex.new
      @failed_notifications = []

      beginning = Time.now

      @connections = []
      10.times{
        connection = Connection.new(@gateway_uri, @certificate, @passphrase)
        connection.open
        @connections << connection
      }
      logger = Logger.new("michel_test.log", 'daily')
      logger.info("Connections creation took: #{Time.now - beginning}")

      beginning = Time.now

      notifications.flatten!
      error_index = send_notifications(notifications, &update_block)
      while error_index > -1
        notifications.shift(error_index + 1)
        notifications.each{|n|n.mark_as_unsent!}
        error_index = send_notifications(notifications, &update_block)
      end

      logger = Logger.new("michel_test.log", 'daily')
      logger.info("finished after #{Time.now - beginning}")

      @failed_notifications
    end

    def get_connection
      Thread.new{
        connection = Connection.new(@gateway_uri, @certificate, @passphrase)
        connection.open
        @connections << connection
      }
      @mutex.synchronize do
        @connections.shift || Connection.new(@gateway_uri, @certificate, @passphrase)
      end
    end

    def send_notifications(*notifications, &update_block)
      return if notifications.empty?
      notifications.flatten!
      error_index = -1

      # Connection.open(@gateway_uri, @certificate, @passphrase) do |connection|
      connection = get_connection
      logger = Logger.new("michel_test.log", 'daily')
      logger.info("get connection")

      ssl = connection.ssl

      Thread.abort_on_exception=true
      read_thread = nil

      write_thread = Thread.new do
        notifications.each_with_index do |notification, index|
          begin
            last_time = Time.now
            next unless notification.kind_of?(Notification)
            next if notification.sent?
            next unless notification.valid?
            notification.id = index
            connection.write(notification.message)
            notification.mark_as_sent!
            logger = Logger.new("michel_test.log", 'daily')
            logger.info("sent_at:#{Time.now.to_s}, diff: #{Time.now - last_time}, token: #{notification.token}, text: #{notification.alert}")

            if block_given? && (index % 200 == 0)
              update_block.call(index)
            end
          rescue => error
            logger = Logger.new("michel_test.log", 'daily')
            logger.error("#{error.inspect}, token: #{notification.token}")
            @mutex.synchronize do
              error_index = index - 1
            end
          end
          # read_thread.exit if index == notifications.size - 1
        end
        # sleep in order to receive last errors from apple in read thread
        # if regular_exit
        logger = Logger.new("michel_test.log", 'daily')
        logger.info("sleep")
        sleep(2)
        read_thread.exit
        # end
      end

      read_thread = Thread.new do
        begin
          read_socket, write_socket, errors = IO.select([ssl], [], [ssl], nil)
          if (read_socket && read_socket[0])
            if error = connection.read(6)
              command, status, index = error.unpack("ccN")
              logger = Logger.new("michel_test.log", 'daily')
              logger.error("error_at:#{Time.now.to_s}, error_code: #{status}, index_error: #{index}")
              write_thread.exit
              error_index = index
              notifications[error_index].apns_error_code = status
              @failed_notifications << notifications[error_index]
              connection.close
              read_thread.exit
            end
          end
        rescue
          redo
        end
      end

      read_thread.join

      # end
      error_index
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
