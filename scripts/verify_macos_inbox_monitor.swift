import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
  fputs("usage: verify_macos_inbox_monitor <app-path>\n", stderr)
  exit(2)
}

let fileManager = FileManager.default
let appURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let executableName = (Bundle(url: appURL)?.object(
  forInfoDictionaryKey: "CFBundleExecutable"
) as? String) ?? "Listenook"
let executableURL = appURL
  .appendingPathComponent("Contents/MacOS")
  .appendingPathComponent(executableName)

guard fileManager.isExecutableFile(atPath: executableURL.path) else {
  fputs("app executable is missing: \(executableURL.path)\n", stderr)
  exit(2)
}

let testRoot = fileManager.temporaryDirectory.appendingPathComponent(
  "listenook-inbox-monitor-\(UUID().uuidString)",
  isDirectory: true
)
let home = testRoot.appendingPathComponent("home", isDirectory: true)
let monitoredFolder = testRoot.appendingPathComponent("Inbox", isDirectory: true)
let support = home
  .appendingPathComponent("Library/Application Support", isDirectory: true)
  .appendingPathComponent("app.capyvibe.listenook", isDirectory: true)
let storageURL = support.appendingPathComponent("inbox_monitor.json")

try fileManager.createDirectory(at: monitoredFolder, withIntermediateDirectories: true)
try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
let storage: [String: Any] = [
  "version": 1,
  "config": [
    "folder_path": monitoredFolder.path,
    "paused": false,
    "extensions": ["wav"],
    "launch_at_login": false,
    "show_tray_icon": true,
  ],
  "records": [:],
]
try JSONSerialization.data(withJSONObject: storage).write(to: storageURL)

func makeWav() -> Data {
  let sampleRate: UInt32 = 8_000
  let sampleCount: UInt32 = 800
  let dataSize = sampleCount * 2
  var bytes = Data()
  func appendASCII(_ value: String) { bytes.append(value.data(using: .ascii)!) }
  func appendLE<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { bytes.append(contentsOf: $0) }
  }
  appendASCII("RIFF")
  appendLE(UInt32(36) + dataSize)
  appendASCII("WAVEfmt ")
  appendLE(UInt32(16))
  appendLE(UInt16(1))
  appendLE(UInt16(1))
  appendLE(sampleRate)
  appendLE(sampleRate * 2)
  appendLE(UInt16(2))
  appendLE(UInt16(16))
  appendASCII("data")
  appendLE(dataSize)
  for index in 0..<sampleCount {
    let phase = Double(index) * 440 * 2 * Double.pi / Double(sampleRate)
    appendLE(Int16(sin(phase) * 4_000))
  }
  return bytes
}

func processedRecordCount() -> Int? {
  guard let data = try? Data(contentsOf: storageURL),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let records = json["records"] as? [String: Any] else {
    return nil
  }
  return records.count
}

var environment = ProcessInfo.processInfo.environment
environment["CFFIXED_USER_HOME"] = home.path

let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = false
configuration.createsNewApplicationInstance = true
configuration.arguments = ["--background"]
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
if let launchError { throw launchError }
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

RunLoop.current.run(until: Date().addingTimeInterval(2))
guard !application.isTerminated else {
  fputs("FAIL: app exited before the monitored file was added\n", stderr)
  exit(1)
}

try makeWav().write(to: monitoredFolder.appendingPathComponent("sample.wav"))

let deadline = Date().addingTimeInterval(12)
while !application.isTerminated && processedRecordCount() != 1 && Date() < deadline {
  RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}

guard !application.isTerminated else {
  fputs("FAIL: app crashed after an audio file was added to the Inbox folder\n", stderr)
  exit(1)
}
guard processedRecordCount() == 1 else {
  fputs("FAIL: monitored audio did not reach Inbox processing\n", stderr)
  exit(1)
}

try fileManager.removeItem(at: monitoredFolder.appendingPathComponent("sample.wav"))
let removalDeadline = Date().addingTimeInterval(5)
while !application.isTerminated && processedRecordCount() != 0 && Date() < removalDeadline {
  RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
guard processedRecordCount() == 0 else {
  fputs("FAIL: removed monitored audio remained in the pending queue\n", stderr)
  exit(1)
}

try makeWav().write(to: monitoredFolder.appendingPathComponent("sample.wav"))
let readdDeadline = Date().addingTimeInterval(12)
while !application.isTerminated && processedRecordCount() != 1 && Date() < readdDeadline {
  RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
guard processedRecordCount() == 1 else {
  fputs("FAIL: re-added monitored audio did not return to the pending queue\n", stderr)
  exit(1)
}

RunLoop.current.run(until: Date().addingTimeInterval(1))
guard !application.isTerminated else {
  fputs("FAIL: app crashed after processing the monitored audio\n", stderr)
  exit(1)
}

print("PASS: monitored audio was removed, re-added, and the app remained running")
