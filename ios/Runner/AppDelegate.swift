import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = registrar(forPlugin: "IrNetShare") {
      let channel = FlutterMethodChannel(name: "ir_net/share", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handleShare(call, result: result)
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Opens the share sheet for an exported quality report, or puts a
  /// screenshot on the pasteboard.
  private func handleShare(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "copyImage" {
      guard let args = call.arguments as? [String: Any], let png = args["png"] as? FlutterStandardTypedData else {
        result(FlutterError(code: "BAD_ARGS", message: "png is required", details: nil))
        return
      }
      UIPasteboard.general.setData(png.data, forPasteboardType: "public.png")
      result(nil)
      return
    }
    guard call.method == "shareFile" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let args = call.arguments as? [String: Any], let path = args["path"] as? String,
          let presenter = topViewController() else {
      result(FlutterError(code: "SHARE_FAILED", message: "Nothing to share from", details: nil))
      return
    }
    let sheet = UIActivityViewController(activityItems: [URL(fileURLWithPath: path)], applicationActivities: nil)
    // iPad shows the sheet as a popover, which needs an anchor.
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = presenter.view
      popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
      popover.permittedArrowDirections = []
    }
    presenter.present(sheet, animated: true)
    result(nil)
  }

  private func topViewController() -> UIViewController? {
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}
