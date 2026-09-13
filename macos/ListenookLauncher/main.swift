import Cocoa

let helperURL = Bundle.main.bundleURL
let mainAppURL = helperURL
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()

let configuration = NSWorkspace.OpenConfiguration()
configuration.arguments = ["--background"]
configuration.activates = false
NSWorkspace.shared.openApplication(
  at: mainAppURL,
  configuration: configuration
) { _, _ in
  NSApp.terminate(nil)
}

NSApp.run()
