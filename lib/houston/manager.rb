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

    def self.push(apn, notifications, packet_size: 10)
      start_time = Time.now
      failed_notifications = []
      num_threads = max_threads notifications.size

      #create progress teller thread before pool, so that if there is threads count limit, it will be limited on pool
      progress_ar = []
      progress_teller = Thread.new do
        Thread.stop

        loop do
          sleep 1
          yield progress_ar.sum if block_given?
        end
      end

      pool = Thread.pool(num_threads)
      if pool.size < num_threads
        apn.logger.error "can't create #{num_threads} threads. Using #{pool.size} threads."

        raise "Can't create threads at all" if pool.size == 0
      end

      groups = notifications.each_slice((notifications.size.to_f/pool.size).ceil.to_i).to_a

      progress_ar = [0] * groups.size
      groups.each.with_index do |group, group_index|
        pool.process do
          failed_notifications << apn.push(group, packet_size: packet_size) do |local_progress|
            progress_ar[group_index] = local_progress
          end
        end
      end

      progress_teller.run
      pool.shutdown
      progress_teller.kill

      apn.logger.info("Done. took #{Time.now-start_time}")
      failed_notifications
    end
  end
end
