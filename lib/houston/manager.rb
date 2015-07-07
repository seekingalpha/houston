require 'thread/pool'

module Houston
  MIN_NOTIFICATIONS = 50
  MAX_THREADS = 140

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
      puts 'cheguei'
      pool = Thread.pool(number_threads)
      puts pool.size
      groups = notifications.each_slice(nthreads).to_a

      threads = []
      pid = Process.pid

      groups.each_with_index do |group, index|
        threads << Thread.new do
          index = 0
          while (index != -1) do
            index, failed = apn.process_push(group)
            failed_notifications << failed if failed
            begin # in the last run it fails...I still need to check why
              group.shift(index + 1) if index && index > -1 && failed
              group.shift(index) if index > -1 && !failed
            rescue
            end
          end
          logger = Logger.new("houston_test.log", 'daily')
          logger.error("#{pid} finished thread#{index}")
        end
      end
      threads.each{|t| t.join}
      failed_notifications
    end
  end
end
