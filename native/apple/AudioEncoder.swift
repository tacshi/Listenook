import AVFoundation
#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

/// The `audio_encoder` channel, shared by the macOS and iOS runners:
/// re-encodes the 16 kHz mono PCM that libmpv extracts into compact AAC for
/// uploads, or into lossless ALAC where no command-line encoder can run (iOS).
enum AudioEncoderChannel {
  static func register(with messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let encoder = AudioEncoder()
    let channel = FlutterMethodChannel(
      name: "app.capyvibe.listenook/audio_encoder",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard let arguments = call.arguments as? [String: Any],
            let inputPath = arguments["inputPath"] as? String,
            let outputPath = arguments["outputPath"] as? String
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      let format: AudioEncoder.Format
      switch call.method {
      case "encodeAac":
        guard let bitRate = arguments["bitRate"] as? Int else {
          result(FlutterMethodNotImplemented)
          return
        }
        format = .aac(bitRate: bitRate)
      case "encodeAlac":
        format = .alac
      default:
        result(FlutterMethodNotImplemented)
        return
      }
      encoder.encode(
        inputURL: URL(fileURLWithPath: inputPath),
        outputURL: URL(fileURLWithPath: outputPath),
        format: format
      ) { error in
        DispatchQueue.main.async {
          if let error {
            result(FlutterError(
              code: format.errorCode,
              message: error.localizedDescription,
              details: nil
            ))
          } else {
            result(nil)
          }
        }
      }
    }
    return channel
  }
}

final class AudioEncoder {
  enum Format {
    case aac(bitRate: Int)
    case alac

    var errorCode: String {
      switch self {
      case .aac: return "compact_audio_encoding_failed"
      case .alac: return "lossless_audio_encoding_failed"
      }
    }

    var name: String {
      switch self {
      case .aac: return "AAC"
      case .alac: return "ALAC"
      }
    }

    var outputSettings: [String: Any] {
      switch self {
      case .aac(let bitRate):
        return [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: 16_000,
          AVNumberOfChannelsKey: 1,
          AVEncoderBitRateKey: bitRate,
        ]
      case .alac:
        return [
          AVFormatIDKey: kAudioFormatAppleLossless,
          AVSampleRateKey: 16_000,
          AVNumberOfChannelsKey: 1,
          AVEncoderBitDepthHintKey: 16,
        ]
      }
    }
  }

  private let queue = DispatchQueue(label: "app.capyvibe.listenook.audio-encoder")

  func encode(
    inputURL: URL,
    outputURL: URL,
    format: Format,
    completion: @escaping (Error?) -> Void
  ) {
    do {
      try? FileManager.default.removeItem(at: outputURL)
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
        outputSettings: format.outputSettings
      )
      writerInput.expectsMediaDataInRealTime = false
      guard writer.canAdd(writerInput) else {
        throw encodingError("The \(format.name) encoder is unavailable.")
      }
      writer.add(writerInput)
      guard writer.startWriting(), reader.startReading() else {
        throw writer.error ?? reader.error
          ?? encodingError("\(format.name) encoding could not start.")
      }
      writer.startSession(atSourceTime: .zero)
      writerInput.requestMediaDataWhenReady(on: queue) {
        while writerInput.isReadyForMoreMediaData {
          if let sample = readerOutput.copyNextSampleBuffer() {
            if !writerInput.append(sample) {
              reader.cancelReading()
              writer.cancelWriting()
              completion(writer.error ?? self.encodingError("\(format.name) encoding failed."))
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
                : writer.error ?? self.encodingError("\(format.name) encoding failed.")
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
      domain: "app.capyvibe.listenook.audio-encoder",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }
}
