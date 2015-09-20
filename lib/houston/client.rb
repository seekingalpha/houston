require 'logger'

module Houston
  APPLE_PRODUCTION_GATEWAY_URI = "apn://gateway.push.apple.com:2195"
  APPLE_PRODUCTION_FEEDBACK_URI = "apn://feedback.push.apple.com:2196"

  APPLE_DEVELOPMENT_GATEWAY_URI = "apn://gateway.sandbox.push.apple.com:2195"
  APPLE_DEVELOPMENT_FEEDBACK_URI = "apn://feedback.sandbox.push.apple.com:2196"

  class Client
    attr_accessor :gateway_uri, :feedback_uri, :certificate, :passphrase, :timeout, :logger

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
      @logger = Logger.new("log/houston_test_#{Time.now.strftime('%Y%m%d')}.log")
      @logger.datetime_format = Time.now.strftime "%Y-%m-%dT%H:%M:%S"
      @logger.formatter = proc do |severity, datetime, progname, msg|
        "#{@pid}: #{datetime} #{severity}: #{msg}\n"
      end
    end

    def process_push(*notifications)
      return if notifications.empty?
      notifications.flatten!

      Connection.open(@gateway_uri, @certificate, @passphrase) do |connection|
        ssl = connection.ssl
        notifications.each_with_index do |notification, index|
          begin
            next unless notification.kind_of?(Notification)
            next unless notification.valid?

            notification.id = index

            connection.write(notification.message)
            last_time = Time.now

            sleep_time = index == notifications.size-1 ? 1 : 0.2 #give apple time to respond on last
            read_socket, write_socket, errors = IO.select([ssl], [], [ssl], sleep_time)
            if (read_socket && read_socket[0])
              if error = connection.read(6)
                command, status, error_index = error.unpack("ccN")
                error_notification = notifications[error_index]
                if error_notification
                  error_notification.apns_error_code = status
                  logger.error("diff: #{Time.now - last_time}, index: #{error_index}, code: #{status}, device_token: #{error_notification.token}")
                else
                  logger.error("diff: #{Time.now - last_time}, index: #{error_index}, code: #{status}, device_token: UNKNOWN")
                end

                return error_index, error_notification
              end
            end
          rescue => e
            logger.error("Exception #{e.class.name}: #{e.message}\n#{e.backtrace[0,5].join("\n")}") rescue nil #want to log, don't care if fails
            return index, notification
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
