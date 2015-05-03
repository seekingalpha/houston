require_relative 'lib/houston/client'
require_relative 'lib/houston/connection'
require_relative 'lib/houston/notification'

module Houston
  class Test

    APN = Houston::Client.production

    TOKEN_ARRAY = ["fake",
                   "74fa92dc18386de64cdba04c20153bd8443315b9006f561871b741225cb6c253",
                   "8425035f1ff2451cfe1e973b86cd97bd94d7885aa829aff79a374ca8f9e5a626",
                   "b40a73442a5ce7bae55e097e2a88218492e87c617aa6430b3a68fb7ec62773eb",
                   "c286e7c1a9119a2c8f9be0de0547cdf26eafe2bb825c090eae06b159bdd5f568",
                   "c5f677e305438c6a1802f70b847a63020db0ba73641fd1de2de34affa37e895f",
                   "cb21603e25209bcefb6fa3f33c56ab6bf8ef68a2a00a05e42a93d3f429fe689f"]

    notification_array = []

    APN.certificate = File.read("/data/seekingalpha/shared/apps/iphone/portfolio/production.pem")
    APN.passphrase = "1qazZAQ!"


    TOKEN_ARRAY.each do |token|
      # Create a notification that alerts a message to the user, plays a sound, and sets the badge on the app
      notification = Houston::Notification.new(device: token)
      notification.alert = "test 8"

      # Notifications can also change the badge count, have a custom sound, have a category identifier, indicate available Newsstand content, or pass along arbitrary data.
      notification.badge = 1
      notification.sound = "sosumi.aiff"
      notification.category = "INVITE_CATEGORY"
      # notification.content_available = true
      notification.custom_data = {foo: "bar"}

      notification_array << notification


      # And... sent! That's all it takes.
      # APN.push(notification)
      # notification.sent?
    end
    index = 0
    while (index != -1) do
      index = APN.push(notification_array)
      notification_array.shift(index + 1) if index > -1
    end

  end
end