import AVFoundation
import Flutter
import MediaPlayer
import UIKit

/// Lock screen, Control Center and headphone controls for whatever Listenook
/// is playing (lib/data/now_playing.dart). Also keeps audio going in the
/// background: the session is long-form spoken audio.
final class NowPlayingChannel {
  private static let shared = NowPlayingChannel()
  private var channel: FlutterMethodChannel?
  private var artworkURL: String?
  private var artwork: MPMediaItemArtwork?
  private var commandsRegistered = false

  static func register(with messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(
      name: "app.capyvibe.listenook/now_playing",
      binaryMessenger: messenger
    )
    shared.channel = channel
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "update":
        shared.update(call.arguments as? [String: Any] ?? [:])
        result(nil)
      case "clear":
        shared.clear()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    shared.observeSession()
    return channel
  }

  private func activateSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
      try session.setActive(true)
    } catch {
      NSLog("Listenook: audio session unavailable: \(error)")
    }
  }

  private func registerCommands() {
    guard !commandsRegistered else { return }
    commandsRegistered = true
    let center = MPRemoteCommandCenter.shared()
    center.playCommand.addTarget { [weak self] _ in self?.send("play") ?? .commandFailed }
    center.pauseCommand.addTarget { [weak self] _ in self?.send("pause") ?? .commandFailed }
    center.togglePlayPauseCommand.addTarget { [weak self] _ in
      self?.send("toggle") ?? .commandFailed
    }
    center.skipForwardCommand.preferredIntervals = [15]
    center.skipForwardCommand.addTarget { [weak self] _ in
      self?.send("skip", ["seconds": 15]) ?? .commandFailed
    }
    center.skipBackwardCommand.preferredIntervals = [15]
    center.skipBackwardCommand.addTarget { [weak self] _ in
      self?.send("skip", ["seconds": -15]) ?? .commandFailed
    }
    center.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      return self?.send("seek", ["positionMs": Int(event.positionTime * 1000)])
        ?? .commandFailed
    }
  }

  private func send(_ name: String, _ arguments: [String: Any] = [:]) -> MPRemoteCommandHandlerStatus {
    guard let channel else { return .noActionableNowPlayingItem }
    var payload = arguments
    payload["name"] = name
    channel.invokeMethod("command", arguments: payload)
    return .success
  }

  private func update(_ item: [String: Any]) {
    activateSession()
    registerCommands()
    let playing = item["playing"] as? Bool ?? false
    let rate = item["rate"] as? Double ?? 1
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: item["title"] as? String ?? "",
      MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(item["positionMs"] as? Int ?? 0) / 1000,
      MPNowPlayingInfoPropertyPlaybackRate: playing ? rate : 0,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
    ]
    if let artist = item["artist"] as? String { info[MPMediaItemPropertyArtist] = artist }
    if let album = item["album"] as? String { info[MPMediaItemPropertyAlbumTitle] = album }
    if let duration = item["durationMs"] as? Int, duration > 0 {
      info[MPMediaItemPropertyPlaybackDuration] = Double(duration) / 1000
    }
    let url = item["artworkUrl"] as? String
    if url == artworkURL, let artwork {
      info[MPMediaItemPropertyArtwork] = artwork
    } else {
      loadArtwork(url)
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
  }

  private func loadArtwork(_ url: String?) {
    artworkURL = url
    artwork = nil
    guard let url, let address = URL(string: url) else { return }
    URLSession.shared.dataTask(with: address) { [weak self] data, _, _ in
      guard let data, let image = UIImage(data: data) else { return }
      DispatchQueue.main.async {
        guard let self, self.artworkURL == url else { return }
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        self.artwork = artwork
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        guard !info.isEmpty else { return }
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
      }
    }.resume()
  }

  private func clear() {
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    MPNowPlayingInfoCenter.default().playbackState = .stopped
    artworkURL = nil
    artwork = nil
  }

  /// Phone calls and other apps pause playback; unplugging headphones does
  /// too, as on every iOS player.
  private func observeSession() {
    let center = NotificationCenter.default
    center.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
      else { return }
      switch type {
      case .began:
        _ = self?.send("pause")
      case .ended:
        let options = AVAudioSession.InterruptionOptions(
          rawValue: notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        )
        if options.contains(.shouldResume) { _ = self?.send("play") }
      @unknown default:
        break
      }
    }
    center.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
      else { return }
      _ = self?.send("pause")
    }
  }
}
