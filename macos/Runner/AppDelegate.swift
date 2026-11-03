import Cocoa
import Darwin
import FlutterMacOS
import ServiceManagement

enum ApplicationIdentity {
  static let bundleIdentifier = "app.capyvibe.listenook"
  static let legacyBundleIdentifier = "app.meowstt.desktop"
  static var displayName = "Listenook"
}

@main
class AppDelegate: FlutterAppDelegate {
  private let navigationChannelName = "app.capyvibe.listenook/navigation"
  private let instanceActivationNotification = Notification.Name(
    "app.capyvibe.listenook.activate-existing-instance"
  )
  private var instanceLockDescriptor: Int32 = -1
  private var ownsInstanceLock = false
  private let applicationChannels = ApplicationChannels()

  /// The app's one engine. It has no window of its own: every window — the
  /// main window and each video player — is created from Dart through
  /// Flutter's windowing API as another view of this engine
  /// (lib/core/windowing/). Multi-view has to be enabled before any view
  /// controller is attached, which is why this is not the template's
  /// `MainFlutterWindow`.
  private(set) var engine: FlutterEngine?

  /// Files opened at launch arrive before this; `OpenFileInbox` queues them
  /// until Dart asks.
  override func applicationDidFinishLaunching(_ notification: Notification) {
    if engine != nil { return }
    // Launched to open documents (a video double-clicked in Finder): Dart
    // keeps the main window hidden while the files arrive.
    let defaultLaunch =
      notification.userInfo?["NSApplicationLaunchIsDefaultLaunchKey"] as? Bool ?? true
    OpenFileInbox.shared.launchedForFiles = !defaultLaunch
    let engine = FlutterEngine(name: "Listenook", project: nil)
    RegisterGeneratedPlugins(registry: engine)
    applicationChannels.register(with: engine.binaryMessenger)
    WindowHandleChannel.shared.attach(engine: engine)
    engine.run(withEntrypoint: nil)
    self.engine = engine
  }

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
    DockIconPolicy.applySaved()
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
      "app.capyvibe.listenook.instance.lock",
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
      withBundleIdentifier: Bundle.main.bundleIdentifier ?? "app.capyvibe.listenook"
    ).first(where: { $0.processIdentifier != currentPID }) {
      existing.activate(options: [.activateAllWindows])
    }
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    let files = urls.filter(\.isFileURL)
    let others = urls.filter { !$0.isFileURL }
    if !others.isEmpty {
      super.application(application, open: others)
    }
    guard !files.isEmpty else { return }
    // Videos open in their own window; the main window stays as it is.
    OpenFileInbox.shared.receive(files.map(\.path))
  }

  @objc private func activatePrimaryInstance(_ notification: Notification) {
    guard ownsInstanceLock else { return }
    invokeNavigation("showWindow", sender: nil)
  }

  @IBAction func showAbout(_ sender: Any?) {
    NSApp.orderFrontStandardAboutPanel(options: [
      .applicationName: ApplicationIdentity.displayName
    ])
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
      WindowHandleChannel.shared.showMainWindow()
    }
    guard let engine else { return }
    let channel = FlutterMethodChannel(
      name: navigationChannelName,
      binaryMessenger: engine.binaryMessenger
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

/// Holds files Finder asked the app to open until Dart takes them, so a
/// double-click that launches the app is not lost while Flutter starts.
final class OpenFileInbox {
  static let shared = OpenFileInbox()

  private var pending: [String] = []
  private var channel: FlutterMethodChannel?
  var launchedForFiles = false

  func attach(_ channel: FlutterMethodChannel) {
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      if call.method == "launchedForFiles" {
        result(self.launchedForFiles)
        return
      }
      guard call.method == "takePendingOpenFiles" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let files = self.pending
      self.pending.removeAll()
      result(files)
    }
  }

  func receive(_ paths: [String]) {
    pending.append(contentsOf: paths)
    channel?.invokeMethod("openFilesAvailable", arguments: nil)
  }
}

/// Shows or hides the Dock icon by switching between the regular and
/// accessory activation policies. The choice is also kept in UserDefaults so
/// the next launch applies it before any window appears.
enum DockIconPolicy {
  private static let defaultsKey = "ShowDockIcon"

  static func applySaved() {
    if UserDefaults.standard.object(forKey: defaultsKey) as? Bool == false {
      NSApp.setActivationPolicy(.accessory)
    }
  }

  static func setVisible(_ visible: Bool) {
    UserDefaults.standard.set(visible, forKey: defaultsKey)
    let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
    guard NSApp.activationPolicy() != policy else { return }
    let wasActive = NSApp.isActive
    NSApp.setActivationPolicy(policy)
    // Switching policy deactivates the app; keep its windows in front.
    if wasActive { NSApp.activate(ignoringOtherApps: true) }
  }
}

final class ApplicationChannels {
  private var launchAtLoginChannel: FlutterMethodChannel?
  private var audioEncoderChannel: FlutterMethodChannel?

  func register(with messenger: FlutterBinaryMessenger) {
    OpenFileInbox.shared.attach(FlutterMethodChannel(
      name: "app.capyvibe.listenook/open_files",
      binaryMessenger: messenger
    ))

    let launchAtLoginChannel = FlutterMethodChannel(
      name: "app.capyvibe.listenook/launch_at_login",
      binaryMessenger: messenger
    )
    launchAtLoginChannel.setMethodCallHandler { call, result in
      if call.method == "setDockIconVisible", let visible = call.arguments as? Bool {
        DockIconPolicy.setVisible(visible)
        result(nil)
        return
      }
      if call.method == "isLegacyRunning" {
        result(!NSRunningApplication.runningApplications(
          withBundleIdentifier: ApplicationIdentity.legacyBundleIdentifier
        ).isEmpty)
        return
      }
      if call.method == "setDisplayName",
         let arguments = call.arguments as? [String: String],
         let name = arguments["name"] {
        ApplicationIdentity.displayName = name
        let chinese = arguments["languageCode"] == "zh"
        if let appItem = NSApp.mainMenu?.items.first,
           let menu = appItem.submenu {
          appItem.title = name
          menu.title = name
          for item in menu.items {
            switch item.action.map(NSStringFromSelector) {
            case "showAbout:", "orderFrontStandardAboutPanel:":
              item.title = chinese ? "关于\(name)" : "About \(name)"
            case "hide:": item.title = chinese ? "隐藏\(name)" : "Hide \(name)"
            case "requestQuit:", "terminate:":
              item.title = chinese ? "退出\(name)" : "Quit \(name)"
            default: break
            }
          }
        }
        result(nil)
        return
      }
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
        // The macOS 12 helper uses the old bundle identifier as a migration alias.
        SMLoginItemSetEnabled("app.meowstt.desktop.Launcher" as CFString, false)
        let helperIdentifier = "app.capyvibe.listenook.Launcher" as CFString
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

    audioEncoderChannel = AudioEncoderChannel.register(with: messenger)
  }
}
