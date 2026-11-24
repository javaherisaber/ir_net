import Cocoa
import FlutterMacOS
import UserNotifications

/// System notifications for IRNet (channel "ir_net/notify"): VPN drops,
/// subscription and Kerio balance warnings. Shown even while IRNet is the
/// active app, since it mostly lives in the menu bar.
class Notifications: NSObject, UNUserNotificationCenterDelegate {
  static let shared = Notifications()
  private var channel: FlutterMethodChannel?

  func register(messenger: FlutterBinaryMessenger) {
    UNUserNotificationCenter.current().delegate = self
    let channel = FlutterMethodChannel(name: "ir_net/notify", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "show", let args = call.arguments as? [String: Any],
        let title = args["title"] as? String, let body = args["body"] as? String
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.show(title: title, body: body, id: args["id"] as? String, result: result)
    }
    self.channel = channel
  }

  private func show(title: String, body: String, id: String?, result: @escaping FlutterResult) {
    let center = UNUserNotificationCenter.current()
    // Asks the first time; later calls return the saved answer.
    center.requestAuthorization(options: [.alert, .sound]) { granted, error in
      guard granted, error == nil else {
        DispatchQueue.main.async { result(false) }
        return
      }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.sound = .default
      // The same id replaces an earlier notification instead of stacking.
      let request = UNNotificationRequest(
        identifier: id ?? UUID().uuidString, content: content, trigger: nil)
      center.add(request) { error in
        DispatchQueue.main.async { result(error == nil) }
      }
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if #available(macOS 11.0, *) {
      completionHandler([.banner, .list, .sound])
    } else {
      completionHandler([.alert, .sound])
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    // Clicking a notification brings IRNet's window forward.
    DispatchQueue.main.async {
      NSApp.activate(ignoringOtherApps: true)
      NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
    completionHandler()
  }
}
