module Houston
  class Manager
    def self.push(apn, *notifications)
      notifications.flatten!
      failed_notifications = []
      groups = notifications.each_slice(2000).to_a
      threads = []

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
          logger.error("finished thread#{index}")
        end
      end
      threads.each{|t| t.join}
      failed_notifications
    end
  end
end