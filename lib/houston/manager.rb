require 'thread/pool'

module Houston
  MIN_NOTIFICATIONS = 50
  MAX_THREADS = ENV['APN_MAX_THREADS'] || 300

  class Manager
    def self.max_threads total
      total = total.to_f
      if total <= MIN_NOTIFICATIONS
        return 1
      end
      if total <= MIN_NOTIFICATIONS*MAX_THREADS
        return (total/MIN_NOTIFICATIONS).ceil.to_i
      end
      return MAX_THREADS
    end

    def self.push(apn, *notifications)
      notifications.flatten!
      failed_notifications = []
      nthreads = max_threads notifications.size
      number_threads = max_threads(notifications.size)
      pool = Thread.pool(number_threads)
      if pool.size < nthreads
        logger = Logger.new("houston_test.log", 'daily')
        logger.error("can't create #{nthreads} threads. Using #{pool.size} threads.")
      end
      groups = notifications.each_slice(nthreads).to_a

      threads = []
      groups.each_with_index do |group, index|
        pool.process do
          index = 0
          while (index != -1) do
            index, failed = apn.process_push(group)
            failed_notifications << failed if failed
            group.shift(index + 1) if index && index > -1 && failed
          end
        end
      end
      pool.shutdown
      failed_notifications
    end
  end
end
