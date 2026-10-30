import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    // dart:io reports a child process's exit through a pipe; a late write to it
    // must not kill the app (the standalone Dart VM ignores SIGPIPE too).
    signal(SIGPIPE, SIG_IGN)
    let flutterViewController = FlutterViewController.init()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Exported reports are saved to Downloads; these open or reveal them.
    // copyImage puts a screenshot on the clipboard.
    let share = FlutterMethodChannel(
      name: "ir_net/share", binaryMessenger: flutterViewController.engine.binaryMessenger)
    share.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any]
      if call.method == "copyImage" {
        guard let png = args?["png"] as? FlutterStandardTypedData else {
          result(FlutterError(code: "BAD_ARGS", message: "png is required", details: nil))
          return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setData(png.data, forType: .png) {
          result(nil)
        } else {
          result(FlutterError(code: "COPY_FAILED", message: "The clipboard refused the image", details: nil))
        }
        return
      }
      guard let path = args?["path"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      let url = URL(fileURLWithPath: path)
      switch call.method {
      case "openFile":
        result(NSWorkspace.shared.open(url))
      case "revealFile":
        NSWorkspace.shared.activateFileViewerSelecting([url])
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
