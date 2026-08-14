import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 3 else {
  fputs(
    "usage: verify_macos_background_lifecycle <app-path> [--unconfigured-menu-bar]\n",
    stderr
  )
  exit(2)
}

let unconfiguredMenuBar =
  CommandLine.arguments.dropFirst(2).first == "--unconfigured-menu-bar"

let fileManager = FileManager.default
let appURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let executableName = (Bundle(url: appURL)?.object(
  forInfoDictionaryKey: "CFBundleExecutable"
) as? String) ?? "MeowSTT"
let executableURL = appURL
  .appendingPathComponent("Contents/MacOS")
  .appendingPathComponent(executableName)

guard fileManager.isExecutableFile(atPath: executableURL.path) else {
  fputs("app executable is missing: \(executableURL.path)\n", stderr)
  exit(2)
}

let testRoot = fileManager.temporaryDirectory.appendingPathComponent(
  "meowstt-background-lifecycle-\(UUID().uuidString)",
  isDirectory: true
)
let home = testRoot.appendingPathComponent("home", isDirectory: true)
let monitoredFolder = testRoot.appendingPathComponent("Inbox", isDirectory: true)
let support = home
  .appendingPathComponent("Library/Application Support", isDirectory: true)
  .appendingPathComponent("app.meowstt.desktop", isDirectory: true)
  .appendingPathComponent("MeowSTT", isDirectory: true)

try fileManager.createDirectory(
  at: monitoredFolder,
  withIntermediateDirectories: true
)
try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
let storage: [String: Any] = [
  "version": 1,
  "config": [
    "folder_path": unconfiguredMenuBar ? "" : monitoredFolder.path,
    "paused": false,
    "extensions": ["mp3", "wav"],
    "launch_at_login": false,
    "show_tray_icon": true,
  ],
  "records": [:],
]
try JSONSerialization.data(withJSONObject: storage).write(
  to: support.appendingPathComponent("inbox_monitor.json")
)

var environment = ProcessInfo.processInfo.environment
environment["CFFIXED_USER_HOME"] = home.path

let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = false
configuration.createsNewApplicationInstance = true
configuration.arguments = unconfiguredMenuBar ? [] : ["--background"]
configuration.environment = environment

var launchedApplication: NSRunningApplication?
var launchError: Error?
NSWorkspace.shared.openApplication(
  at: appURL,
  configuration: configuration
) { application, error in
  launchedApplication = application
  launchError = error
}

let launchDeadline = Date().addingTimeInterval(5)
while launchedApplication == nil && launchError == nil && Date() < launchDeadline {
  RunLoop.current.run(until: Date().addingTimeInterval(0.02))
}
if let launchError {
  throw launchError
}
guard let application = launchedApplication else {
  fputs("launch timed out\n", stderr)
  exit(2)
}

defer {
  if !application.isTerminated {
    application.terminate()
    let deadline = Date().addingTimeInterval(2)
    while !application.isTerminated && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    if !application.isTerminated {
      application.forceTerminate()
    }
  }
  try? fileManager.removeItem(at: testRoot)
}

let pid = application.processIdentifier

func windows(for pid: pid_t) -> [[String: Any]] {
  guard let values = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements],
    kCGNullWindowID
  ) as? [[String: Any]] else {
    return []
  }
  return values.filter {
    ($0[kCGWindowOwnerPID as String] as? Int32) == pid
  }
}

func bounds(of window: [String: Any]) -> CGRect? {
  guard let value = window[kCGWindowBounds as String] else { return nil }
  return CGRect(dictionaryRepresentation: value as! CFDictionary)
}

func hasVisibleMainWindow(pid: pid_t) -> Bool {
  windows(for: pid).contains { window in
    guard (window[kCGWindowLayer as String] as? Int) == 0,
          let frame = bounds(of: window) else {
      return false
    }
    return frame.width > 100 && frame.height > 100
  }
}

func hasStatusItem(pid: pid_t) -> Bool {
  let applicationElement = AXUIElementCreateApplication(pid)
  var extras: CFTypeRef?
  let extrasResult = AXUIElementCopyAttributeValue(
    applicationElement,
    kAXExtrasMenuBarAttribute as CFString,
    &extras
  )
  guard extrasResult == .success, let extras else { return false }
  var children: CFTypeRef?
  let childrenResult = AXUIElementCopyAttributeValue(
    extras as! AXUIElement,
    kAXChildrenAttribute as CFString,
    &children
  )
  guard childrenResult == .success else { return false }
  return (children as? [AXUIElement])?.isEmpty == false
}

func wait(
  timeout: TimeInterval,
  until condition: () -> Bool
) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  repeat {
    if condition() { return true }
    if application.isTerminated { return false }
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
  } while Date() < deadline
  return condition()
}

let statusItemVisible = wait(timeout: 5) { hasStatusItem(pid: pid) }
if unconfiguredMenuBar {
  if statusItemVisible {
    print("PASS: enabled menu-bar item appears without an Inbox folder")
    exit(0)
  }
  fputs("FAIL: enabled menu-bar item is absent without an Inbox folder\n", stderr)
  exit(1)
}
let backgroundReady = wait(timeout: 5) { !hasVisibleMainWindow(pid: pid) }

var reopenSent = false
if backgroundReady {
  let target = NSAppleEventDescriptor(processIdentifier: pid)
  let event = NSAppleEventDescriptor(
    eventClass: AEEventClass(kCoreEventClass),
    eventID: AEEventID(kAEReopenApplication),
    targetDescriptor: target,
    returnID: AEReturnID(kAutoGenerateReturnID),
    transactionID: AETransactionID(kAnyTransactionID)
  )
  do {
    _ = try event.sendEvent(options: [.noReply], timeout: 2)
    reopenSent = true
  } catch {
    fputs("unable to send Dock-reopen event: \(error)\n", stderr)
  }
}
let reopened = reopenSent && wait(timeout: 5) { hasVisibleMainWindow(pid: pid) }

if statusItemVisible {
  print("PASS: configured menu-bar item is present")
} else {
  fputs("FAIL: configured menu-bar item is absent\n", stderr)
}
if reopened {
  print("PASS: Dock-reopen event restored the hidden window")
} else {
  fputs("FAIL: Dock-reopen event did not restore the hidden window\n", stderr)
}

if !statusItemVisible || !reopened {
  exit(1)
}
