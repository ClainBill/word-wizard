import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // The dictionary is a bundle resource (dictionary.db in the Runner
    // target) and sqlite reads it straight from the bundle, read-only — no
    // copy, no second 470 MB on disk. Android has to copy (see MainActivity).
    let channel = FlutterMethodChannel(
      name: "word_wizard/dictionary", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "locate":
        result(Bundle.main.path(forResource: "dictionary", ofType: "db"))
      case "install":
        result(FlutterError(code: "unsupported", message: "iOS opens the bundle file in place", details: nil))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
