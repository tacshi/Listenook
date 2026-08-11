import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  @IBAction func showSettings(_ sender: Any?) {
    mainFlutterWindow?.makeKeyAndOrderFront(sender)
    NSApp.activate(ignoringOtherApps: true)

    guard let flutterViewController =
      mainFlutterWindow?.contentViewController as? FlutterViewController
    else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "app.meowstt.desktop/navigation",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.invokeMethod("showSettings", arguments: nil)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
