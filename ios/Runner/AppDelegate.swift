import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Kept alive for the life of the app; each owns its method handler.
  private var channels: [FlutterMethodChannel] = []

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    channels = [
      AudioEncoderChannel.register(with: messenger),
      OpenFileInbox.shared.attach(to: messenger),
      FilesChannel.register(with: messenger),
      NowPlayingChannel.register(with: messenger),
      BackgroundActivityChannel.register(with: messenger),
      KeyCommandMenu.shared.attach(to: messenger),
      SpeechEngineChannel.register(with: messenger),
    ]
  }
}
