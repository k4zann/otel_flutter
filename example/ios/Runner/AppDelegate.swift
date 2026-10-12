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
    // Native crash for the "Native crash" button (reported on next launch).
    let messenger = engineBridge.pluginRegistry.registrar(forPlugin: "ExampleNative")!.messenger()
    FlutterMethodChannel(name: "example/native", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in
        if call.method == "crash" { fatalError("Native crash from the example") }
        result(FlutterMethodNotImplemented)
      }
  }
}
