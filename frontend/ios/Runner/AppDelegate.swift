import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Required so flutter_local_notifications can display alerts in foreground.
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    }
    GeneratedPluginRegistrant.register(with: self)

    // Serves DeviceTimeZoneService (TD-066 F2). Dart cannot obtain an IANA
    // zone id on its own, and owner decision D2 rules out a new pub
    // dependency. Registered after the plugin registrant so it cannot be
    // overwritten by a plugin claiming the same name.
    if let controller = window?.rootViewController as? FlutterViewController {
      FlutterMethodChannel(
        name: "com.homesync.app/timezone",
        binaryMessenger: controller.binaryMessenger
      ).setMethodCallHandler { call, result in
        if call.method == "getLocalTimeZone" {
          result(TimeZone.current.identifier)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
