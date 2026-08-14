import Cocoa
import FlutterMacOS
import ServiceManagement

@main
class AppDelegate: FlutterAppDelegate {
  private let navigationChannelName = "app.meowstt.desktop/navigation"

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    guard let flutterViewController =
      mainFlutterWindow?.contentViewController as? FlutterViewController
    else {
      return
    }
    FlutterMethodChannel(
      name: "app.meowstt.desktop/launch_at_login",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    ).setMethodCallHandler { call, result in
      guard call.method == "setEnabled", let enabled = call.arguments as? Bool else {
        result(FlutterMethodNotImplemented)
        return
      }
      if #available(macOS 13.0, *) {
        do {
          if enabled {
            if SMAppService.mainApp.status != .enabled {
              try SMAppService.mainApp.register()
            }
          } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
          }
          result(nil)
        } catch {
          result(FlutterError(
            code: "launch_at_login_failed",
            message: error.localizedDescription,
            details: nil
          ))
        }
      } else {
        let helperIdentifier = "app.meowstt.desktop.Launcher" as CFString
        if SMLoginItemSetEnabled(helperIdentifier, enabled) {
          result(nil)
        } else {
          result(FlutterError(
            code: "launch_at_login_failed",
            message: "The login-item helper could not be updated.",
            details: nil
          ))
        }
      }
    }
  }

  @IBAction func showSettings(_ sender: Any?) {
    invokeNavigation("showSettings", sender: sender)
  }

  @IBAction func requestQuit(_ sender: Any?) {
    invokeNavigation("requestQuit", sender: sender)
  }

  private func invokeNavigation(_ method: String, sender: Any?) {
    if method != "requestQuit" {
      mainFlutterWindow?.makeKeyAndOrderFront(sender)
      NSApp.activate(ignoringOtherApps: true)
    }

    guard let flutterViewController =
      mainFlutterWindow?.contentViewController as? FlutterViewController
    else {
      return
    }
    let channel = FlutterMethodChannel(
      name: navigationChannelName,
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.invokeMethod(method, arguments: nil)
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    invokeNavigation("showInbox", sender: sender)
    return true
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
