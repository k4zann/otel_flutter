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
    // Native crash (reported on next launch) and main-thread freeze for the
    // example's buttons.
    let messenger = engineBridge.pluginRegistry.registrar(forPlugin: "ExampleNative")!.messenger()
    FlutterMethodChannel(name: "example/native", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in
        switch call.method {
        case "crash":
          fatalError("Native crash from the example")
        case "block":
          // Same 20 s as Android. iOS shows no ANR dialog: the app resumes,
          // and Dart (on the main thread too) reports the freeze as a stall.
          Thread.sleep(forTimeInterval: 20)
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
  }
}
