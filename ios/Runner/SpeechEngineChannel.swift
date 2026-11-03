import Flutter
import Foundation
import ListenookSpeechCore
import os

/// Local transcription inside the app (lib/data/local_speech_channel.dart):
/// the same engine and JSON protocol as the macOS worker process, which iOS
/// apps cannot start. One command runs at a time, off the main thread.
final class SpeechEngineChannel {
  private static let shared = SpeechEngineChannel()
  private var channel: FlutterMethodChannel?
  private var tasks: [String: Task<Void, Never>] = [:]

  /// Free memory a command needs before loading its model (bytes). Below
  /// this the system would end the app part-way through.
  private static let requiredMemory: [String: UInt64] = [
    "transcribe-qwen3": 3 << 30,
    "transcribe-moss": 2 << 30,
    "align-qwen3": 2 << 30,
  ]

  static func register(with messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(
      name: "app.capyvibe.listenook/speech_engine",
      binaryMessenger: messenger
    )
    shared.channel = channel
    channel.setMethodCallHandler { call, result in
      let arguments = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "capabilities":
        result(capabilities())
      case "run":
        shared.run(arguments, result: result)
      case "cancel":
        if let id = arguments["id"] as? String { shared.tasks[id]?.cancel() }
        result(nil)
      case "excludeFromBackup":
        result(excludeFromBackup(arguments["path"] as? String))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    return channel
  }

  private static func capabilities() -> [String: Any] {
    #if targetEnvironment(simulator)
    let simulator = true
    #else
    let simulator = false
    #endif
    return [
      "physicalMemory": ProcessInfo.processInfo.physicalMemory,
      "osMajor": ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
      "isSimulator": simulator,
    ]
  }

  private static func excludeFromBackup(_ path: String?) -> Bool {
    guard let path else { return false }
    var url = URL(fileURLWithPath: path)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    return (try? url.setResourceValues(values)) != nil
  }

  private func run(_ arguments: [String: Any], result: @escaping FlutterResult) {
    guard let id = arguments["id"] as? String,
          let command = arguments["command"] as? String,
          let json = (arguments["request"] as? String)?.data(using: .utf8),
          let request = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
    else {
      result(FlutterError(code: "local_worker_request_invalid", message: nil, details: nil))
      return
    }
    guard tasks.isEmpty else {
      result(FlutterError(
        code: "local_worker_busy",
        message: "Another local speech task is running.",
        details: nil
      ))
      return
    }
    let required = Self.requiredMemory[command] ?? 0
    guard UInt64(os_proc_available_memory()) >= required else {
      result(FlutterError(code: "local_stt_insufficient_memory", message: nil, details: nil))
      return
    }
    let channel = self.channel
    tasks[id] = Task.detached(priority: .userInitiated) { [weak self] in
      let reply: Any
      do {
        let output = try await SpeechEngine.run(command: command, request: request) {
          fraction, detail in
          DispatchQueue.main.async {
            channel?.invokeMethod(
              "progress",
              arguments: ["id": id, "fraction": fraction as Any, "detail": detail]
            )
          }
        }
        let data = try JSONSerialization.data(withJSONObject: output)
        reply = String(decoding: data, as: UTF8.self)
      } catch is CancellationError {
        reply = FlutterError(code: "cancelled", message: nil, details: nil)
      } catch let failure as WorkerFailure {
        reply = FlutterError(code: failure.code, message: failure.message, details: nil)
      } catch {
        reply = FlutterError(
          code: "local_worker_failed",
          message: SpeechEngine.safeMessage(error.localizedDescription),
          details: nil
        )
      }
      DispatchQueue.main.async {
        self?.tasks[id] = nil
        result(reply)
      }
    }
  }
}
