require 'thread/pool'

module Houston
  MIN_NOTIFICATIONS = 50
  MAX_THREADS = ENV['APN_MAX_THREADS'] || 300

  class Manager
    def self.max_threads total
      total = total.to_f
      if total <= MIN_NOTIFICATIONS then 1
      elsif total <= MIN_NOTIFICATIONS*MAX_THREADS then (total/MIN_NOTIFICATIONS).ceil.to_i
      else MAX_THREADS
      end
    end

    def self.push(apn, *notifications)
      notifications.flatten!
      failed_notifications = []
        logger = Logger.new("houston_test.log", 'daily')
        logger.error("can't create #{nthreads} threads. Using #{pool.size} threads.")
      num_threads = max_threads notifications.size
      pool = Thread.pool(num_threads)
      if pool.size < num_threads

        raise "Can't create threads at all" if pool.size == 0
      end

      groups = notifications.each_slice((notifications.size.to_f/pool.size).ceil.to_i).to_a

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
