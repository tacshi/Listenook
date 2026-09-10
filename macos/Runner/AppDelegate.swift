import AVFoundation
import Cocoa
import Darwin
import FlutterMacOS
import ServiceManagement

@main
class AppDelegate: FlutterAppDelegate {
  private let navigationChannelName = "app.meowstt.desktop/navigation"
  private let instanceActivationNotification = Notification.Name(
    "app.meowstt.desktop.activate-existing-instance"
  )
  private var instanceLockDescriptor: Int32 = -1
  private var ownsInstanceLock = false

  override func applicationWillFinishLaunching(_ notification: Notification) {
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(activatePrimaryInstance(_:)),
      name: instanceActivationNotification,
      object: nil,
      suspensionBehavior: .deliverImmediately
    )
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
      super.applicationWillFinishLaunching(notification)
      return
    }
    guard claimInstanceLock() else {
      notifyPrimaryInstance()
      NSApp.terminate(nil)
      return
    }
    super.applicationWillFinishLaunching(notification)
  }

  deinit {
    DistributedNotificationCenter.default().removeObserver(self)
    if instanceLockDescriptor >= 0 {
      Darwin.lockf(instanceLockDescriptor, F_ULOCK, 0)
      Darwin.close(instanceLockDescriptor)
    }
  }

  private func claimInstanceLock() -> Bool {
    let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "app.meowstt.desktop.instance.lock",
      isDirectory: false
    )
    let descriptor = Darwin.open(
      lockURL.path,
      O_CREAT | O_RDWR,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
      // A temporary-directory failure should not make the app unusable.
      ownsInstanceLock = true
      return true
    }
    if Darwin.lockf(descriptor, F_TLOCK, 0) == 0 {
      instanceLockDescriptor = descriptor
      ownsInstanceLock = true
      return true
    }
    Darwin.close(descriptor)
    return false
  }

  private func notifyPrimaryInstance() {
    DistributedNotificationCenter.default().postNotificationName(
      instanceActivationNotification,
      object: nil,
      userInfo: nil,
      deliverImmediately: true
    )
    let currentPID = ProcessInfo.processInfo.processIdentifier
    if let existing = NSRunningApplication.runningApplications(
      withBundleIdentifier: Bundle.main.bundleIdentifier ?? "app.meowstt.desktop"
    ).first(where: { $0.processIdentifier != currentPID }) {
      existing.activate(options: [.activateAllWindows])
    }
  }

  @objc private func activatePrimaryInstance(_ notification: Notification) {
    guard ownsInstanceLock else { return }
    invokeNavigation("showWindow", sender: nil)
  }

  @IBAction func showSettings(_ sender: Any?) {
    invokeNavigation("showSettings", sender: sender)
  }

  @IBAction func checkForUpdates(_ sender: Any?) {
    invokeNavigation("checkForUpdates", sender: sender)
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
    invokeNavigation("showWindow", sender: sender)
    return true
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

final class ApplicationChannels {
  private let compactAudioEncoder = CompactAudioEncoder()
  private var launchAtLoginChannel: FlutterMethodChannel?
  private var audioEncoderChannel: FlutterMethodChannel?

  func register(with messenger: FlutterBinaryMessenger) {
    let launchAtLoginChannel = FlutterMethodChannel(
      name: "app.meowstt.desktop/launch_at_login",
      binaryMessenger: messenger
    )
    launchAtLoginChannel.setMethodCallHandler { call, result in
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
    self.launchAtLoginChannel = launchAtLoginChannel

    let audioEncoderChannel = FlutterMethodChannel(
      name: "app.meowstt.desktop/audio_encoder",
      binaryMessenger: messenger
    )
    audioEncoderChannel.setMethodCallHandler { [compactAudioEncoder] call, result in
      guard call.method == "encodeAac",
            let arguments = call.arguments as? [String: Any],
            let inputPath = arguments["inputPath"] as? String,
            let outputPath = arguments["outputPath"] as? String,
            let bitRate = arguments["bitRate"] as? Int
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      compactAudioEncoder.encodeAac(
        inputURL: URL(fileURLWithPath: inputPath),
        outputURL: URL(fileURLWithPath: outputPath),
        bitRate: bitRate
      ) { error in
        DispatchQueue.main.async {
          if let error {
            result(FlutterError(
              code: "compact_audio_encoding_failed",
              message: error.localizedDescription,
              details: nil
            ))
          } else {
            result(nil)
          }
        }
      }
    }
    self.audioEncoderChannel = audioEncoderChannel
  }
}

final class CompactAudioEncoder {
  private let queue = DispatchQueue(label: "app.meowstt.desktop.audio-encoder")

  func encodeAac(
    inputURL: URL,
    outputURL: URL,
    bitRate: Int,
    completion: @escaping (Error?) -> Void
  ) {
    do {
      let asset = AVURLAsset(url: inputURL)
      guard let track = asset.tracks(withMediaType: .audio).first else {
        throw encodingError("The extracted audio has no audio track.")
      }
      let reader = try AVAssetReader(asset: asset)
      let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
      guard reader.canAdd(readerOutput) else {
        throw encodingError("The extracted audio cannot be read.")
      }
      reader.add(readerOutput)

      let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
      let writerInput = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: 16_000,
          AVNumberOfChannelsKey: 1,
          AVEncoderBitRateKey: bitRate,
        ]
      )
      writerInput.expectsMediaDataInRealTime = false
      guard writer.canAdd(writerInput) else {
        throw encodingError("The AAC encoder is unavailable.")
      }
      writer.add(writerInput)
      guard writer.startWriting(), reader.startReading() else {
        throw writer.error ?? reader.error ?? encodingError("AAC encoding could not start.")
      }
      writer.startSession(atSourceTime: .zero)
      writerInput.requestMediaDataWhenReady(on: queue) {
        while writerInput.isReadyForMoreMediaData {
          if let sample = readerOutput.copyNextSampleBuffer() {
            if !writerInput.append(sample) {
              reader.cancelReading()
              writer.cancelWriting()
              completion(writer.error ?? self.encodingError("AAC encoding failed."))
              return
            }
            continue
          }
          if reader.status == .failed {
            writer.cancelWriting()
            completion(reader.error ?? self.encodingError("The extracted audio could not be read."))
            return
          }
          writerInput.markAsFinished()
          writer.finishWriting {
            completion(
              writer.status == .completed
                ? nil
                : writer.error ?? self.encodingError("AAC encoding failed.")
            )
          }
          return
        }
      }
    } catch {
      completion(error)
    }
  }

  private func encodingError(_ message: String) -> NSError {
    NSError(
      domain: "app.meowstt.desktop.audio-encoder",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }
}
