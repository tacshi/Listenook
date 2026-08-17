import AppKit
import CoreGraphics
import Darwin

guard CommandLine.arguments.count >= 2 else {
  fputs(
    "usage: measure_macos_startup <app-path> [maximum-loading-screen-ms]\n",
    stderr
  )
  exit(2)
}

let appURL = URL(fileURLWithPath: CommandLine.arguments[1])
let maximumLoadingMilliseconds = CommandLine.arguments.count >= 3
  ? Int(CommandLine.arguments[2]) ?? 1_500
  : 1_500
let configuration = NSWorkspace.OpenConfiguration()
configuration.createsNewApplicationInstance = true
configuration.activates = false

let startedAt = DispatchTime.now()
var launched: NSRunningApplication?
var launchError: Error?
NSWorkspace.shared.openApplication(
  at: appURL,
  configuration: configuration
) { application, error in
  launched = application
  launchError = error
}

let launchDeadline = Date().addingTimeInterval(5)
while launched == nil && launchError == nil && Date() < launchDeadline {
  RunLoop.current.run(until: Date().addingTimeInterval(0.01))
}

if let launchError {
  fputs("launch failed: \(launchError)\n", stderr)
  exit(2)
}
guard let application = launched else {
  fputs("launch timed out\n", stderr)
  exit(2)
}

defer {
  application.terminate()
  usleep(150_000)
  if !application.isTerminated {
    application.forceTerminate()
  }
}

struct VisibleWindow {
  let id: CGWindowID
  let bounds: CGRect
}

func elapsedMilliseconds() -> Int {
  let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds
  return Int(elapsed / 1_000_000)
}

func visibleWindow(pid: pid_t) -> VisibleWindow? {
  guard let windows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements],
    kCGNullWindowID
  ) as? [[String: Any]] else {
    return nil
  }
  for window in windows {
    guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
          (window[kCGWindowLayer as String] as? Int) == 0,
          let number = window[kCGWindowNumber as String] as? NSNumber,
          let boundsValue = window[kCGWindowBounds as String],
          let bounds = CGRect(dictionaryRepresentation: boundsValue as! CFDictionary),
          bounds.width > 100,
          bounds.height > 100 else {
      continue
    }
    return VisibleWindow(id: CGWindowID(number.uint32Value), bounds: bounds)
  }
  return nil
}

func sampledPixels(window: VisibleWindow) -> [UInt8]? {
  guard let image = CGWindowListCreateImage(
    .null,
    .optionIncludingWindow,
    window.id,
    [.boundsIgnoreFraming, .nominalResolution]
  ), let data = image.dataProvider?.data,
     let bytes = CFDataGetBytePtr(data) else {
    return nil
  }
  let width = image.width
  let height = image.height
  let bytesPerRow = image.bytesPerRow
  let bytesPerPixel = image.bitsPerPixel / 8
  guard bytesPerPixel >= 4 else { return nil }
  var sampled: [UInt8] = []
  sampled.reserveCapacity((width / 8 + 1) * (height / 8 + 1) * 3)
  for y in stride(from: 0, to: height, by: 8) {
    for x in stride(from: 0, to: width, by: 8) {
      let offset = y * bytesPerRow + x * bytesPerPixel
      sampled.append(bytes[offset])
      sampled.append(bytes[offset + 1])
      sampled.append(bytes[offset + 2])
    }
  }
  return sampled
}

func changedPixelRatio(_ first: [UInt8], _ second: [UInt8]) -> Double {
  guard first.count == second.count, !first.isEmpty else { return 1.0 }
  var changed = 0
  let pixelCount = first.count / 3
  for pixel in 0..<pixelCount {
    let offset = pixel * 3
    let difference = max(
      abs(Int(first[offset]) - Int(second[offset])),
      abs(Int(first[offset + 1]) - Int(second[offset + 1])),
      abs(Int(first[offset + 2]) - Int(second[offset + 2]))
    )
    if difference > 28 {
      changed += 1
    }
  }
  return Double(changed) / Double(pixelCount)
}

var visibleAt: Int?
var loadingBaseline: [UInt8]?
var readyAt: Int?
var maximumChange = 0.0
let observationSeconds = max(
  8.0,
  Double(maximumLoadingMilliseconds) / 1_000.0 + 3.0
)
let deadline = Date().addingTimeInterval(observationSeconds)
while Date() < deadline, readyAt == nil {
  if let window = visibleWindow(pid: application.processIdentifier),
     let pixels = sampledPixels(window: window) {
    if visibleAt == nil {
      visibleAt = elapsedMilliseconds()
      loadingBaseline = pixels
    } else if let loadingBaseline {
      let change = changedPixelRatio(loadingBaseline, pixels)
      maximumChange = max(maximumChange, change)
      if change >= 0.015 {
        readyAt = elapsedMilliseconds()
      }
    }
  }
  usleep(50_000)
}

guard let visibleAt else {
  fputs("FAIL: no visible app window observed\n", stderr)
  exit(2)
}
guard let readyAt else {
  fputs(
    "FAIL: startup screen did not transition within \(observationSeconds)s " +
    "(max change \(maximumChange))\n",
    stderr
  )
  exit(1)
}

print("visible_ms=\(visibleAt) ready_ms=\(readyAt) transition_ms=\(readyAt - visibleAt)")
let loadingMilliseconds = readyAt - visibleAt
if loadingMilliseconds > maximumLoadingMilliseconds {
  fputs(
    "FAIL: loading screen time \(loadingMilliseconds)ms exceeds " +
    "\(maximumLoadingMilliseconds)ms budget\n",
    stderr
  )
  exit(1)
}
print("PASS: loading screen cleared within \(maximumLoadingMilliseconds)ms")
