import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let ok = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    if let controller = window?.rootViewController as? FlutterViewController {
      Self.registerUaBundleChannel(messenger: controller.binaryMessenger)
    }
    return ok
  }

  /// 对齐 XMSport AFNetworking：CFBundleExecutable ?: CFBundleIdentifier
  /// Flutter 默认 executable 为 Runner 时改用 CFBundleName
  static func registerUaBundleChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "xm.ua/bundle_info", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "userAgentAppToken" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let info = Bundle.main.infoDictionary ?? [:]
      var token = (info[kCFBundleExecutableKey as String] as? String)
        ?? (info[kCFBundleIdentifierKey as String] as? String)
        ?? "App"
      if token == "Runner",
         let bundleName = info["CFBundleName"] as? String,
         !bundleName.isEmpty {
        token = bundleName
      }
      result(token)
    }
  }
}
