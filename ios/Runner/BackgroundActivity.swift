import Flutter
import UIKit

/// Background time for work the user started (lib/data/background_activity.dart).
/// One task covers all of it: Dart begins it when work starts and ends it
/// when the last piece finishes.
enum BackgroundActivityChannel {
  private static var task: UIBackgroundTaskIdentifier = .invalid

  static func register(with messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(
      name: "app.capyvibe.listenook/background_activity",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "begin":
        begin()
        result(nil)
      case "end":
        end()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    return channel
  }

  private static func begin() {
    guard task == .invalid else { return }
    task = UIApplication.shared.beginBackgroundTask(withName: "Listenook work") {
      // Out of time: the app is suspended and the work continues (or fails
      // and can be retried) when it comes back.
      end()
    }
  }

  private static func end() {
    guard task != .invalid else { return }
    UIApplication.shared.endBackgroundTask(task)
    task = .invalid
  }
}
