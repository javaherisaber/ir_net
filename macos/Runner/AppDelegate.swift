import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  var channel: FlutterMethodChannel?

  override func applicationDidFinishLaunching(_ aNotification: Notification) {
      let controller = mainFlutterWindow?.contentViewController as! FlutterViewController
      channel = FlutterMethodChannel(name: "ir_net/system_events",
                                     binaryMessenger: controller.engine.binaryMessenger)

      NSWorkspace.shared.notificationCenter.addObserver(
          self,
          selector: #selector(didWake),
          name: NSWorkspace.didWakeNotification,
          object: nil
      )
      super.applicationDidFinishLaunching(aNotification)
  }

  @objc func didWake(_ notification: Notification) {
      channel?.invokeMethod("onMacOsWake", arguments: nil)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
