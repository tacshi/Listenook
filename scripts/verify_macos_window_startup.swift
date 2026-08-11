import AppKit
import CoreGraphics
import Darwin

guard CommandLine.arguments.count == 2 else {
  fputs("usage: verify_macos_window_startup <app-path>\n", stderr)
  exit(2)
}

let appURL = URL(fileURLWithPath: CommandLine.arguments[1])
let configuration = NSWorkspace.OpenConfiguration()
configuration.createsNewApplicationInstance = true
configuration.activates = false

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

func visibleWindowBounds(pid: pid_t) -> CGRect? {
  guard let windows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements],
    kCGNullWindowID
  ) as? [[String: Any]] else {
    return nil
  }
  for window in windows {
    guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
          (window[kCGWindowLayer as String] as? Int) == 0,
          let boundsValue = window[kCGWindowBounds as String] else {
      continue
    }
    guard let bounds = CGRect(
            dictionaryRepresentation: boundsValue as! CFDictionary
          ),
          bounds.width > 100,
          bounds.height > 100 else {
      continue
    }
    return bounds
  }
  return nil
}

var samples: [(Int, CGRect)] = []
var visibleSamplesRemaining = 100
for tick in 0..<600 {
  if let bounds = visibleWindowBounds(pid: application.processIdentifier) {
    samples.append((tick * 10, bounds))
    visibleSamplesRemaining -= 1
    if visibleSamplesRemaining == 0 {
      break
    }
  }
  usleep(10_000)
}

guard !samples.isEmpty else {
  fputs("no visible app window observed\n", stderr)
  exit(2)
}

func perceptiblyDiffers(_ first: CGRect, from second: CGRect) -> Bool {
  let differences = [
    abs(first.origin.x - second.origin.x),
    abs(first.origin.y - second.origin.y),
    abs(first.width - second.width),
    abs(first.height - second.height),
  ]
  return differences.max()! > 4
}

var transitions: [(Int, CGRect)] = []
for sample in samples {
  if transitions.last.map({ perceptiblyDiffers(sample.1, from: $0.1) }) ?? true {
    transitions.append(sample)
  }
}

for transition in transitions {
  let bounds = transition.1
  print(
    "t=\(transition.0)ms " +
    "x=\(Int(bounds.origin.x)) y=\(Int(bounds.origin.y)) " +
    "w=\(Int(bounds.width)) h=\(Int(bounds.height))"
  )
}

if transitions.count > 1 {
  fputs("FAIL: visible window bounds changed during startup\n", stderr)
  exit(1)
}

print("PASS: first visible bounds remained stable")
