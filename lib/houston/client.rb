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
      @pid = Process.pid
    end

    def process_push(*notifications)
      return if notifications.empty?
      notifications.flatten!

      Connection.open(@gateway_uri, @certificate, @passphrase) do |connection|
        ssl = connection.ssl
        last_time = Time.now

        notifications.each_with_index do |notification, index|
          begin
            next unless notification.kind_of?(Notification)
            next if notification.sent?
            next unless notification.valid?

            notification.id = index

            connection.write(notification.message)
            notification.mark_as_sent!
            logger = Logger.new("houston_test.log", 'daily')
            logger.info("#{@pid} sent_at:#{Time.now.to_s}, connection: #{connection}, diff: #{Time.now - last_time}")
            last_time = Time.now

            read_socket, write_socket, errors = IO.select([ssl], [], [ssl], 0.2)
            if (read_socket && read_socket[0])
              if error = connection.read(6)
                command, status, error_index = error.unpack("ccN")
                notification.apns_error_code = status
                notification.mark_as_unsent!
                logger = Logger.new("houston_test.log", 'daily')
                logger.error("#{@pid} error_at:#{Time.now.to_s}, diff: #{Time.now - last_time}, error_code: #{status}, device_token: #{notification.token}")
                last_time = Time.now
                error_index ||= index
                return error_index, notification
              end
            end
          rescue Exception => e
            logger = Logger.new("houston_test.log", 'daily')
            logger.error("#{@pid} GENERAL EXCEPTION: #{e.message}")
            return index, nil
          end
        end
      end
      return -1, nil
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
