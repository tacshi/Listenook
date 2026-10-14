import Cocoa
import FlutterMacOS

// The app has no window class of its own any more: every window (the main
// window and each video player) is created from Dart through Flutter's
// windowing API as a view of the one engine `AppDelegate` starts. This file
// keeps the native helpers those windows need.

/// Native operations on the windows Dart creates through Flutter's windowing
/// API (`lib/core/windowing/window_handle_channel.dart`), for what that API
/// does not offer: hiding without destroying, starting hidden, aspect-ratio
/// locking, title bar styling and wiring the main window into native services.
///
/// Windows are addressed by their `NSWindow*` as an integer. A handle is only
/// honoured if it still names one of the app's windows, so a call racing a
/// window's destruction is a no-op rather than a dangling pointer.
final class WindowHandleChannel: NSObject {
  static let shared = WindowHandleChannel()

  private var channel: FlutterMethodChannel?
  private(set) weak var mainWindow: NSWindow?
  private var titlebarFaders: [ObjectIdentifier: PlayerTitlebarFader] = [:]
  private var keepHidden: HiddenAtLaunch?
  let transcriptStructureCursor = TranscriptStructureCursorController()

  func attach(engine: FlutterEngine) {
    let channel = FlutterMethodChannel(
      name: "app.capyvibe.listenook/window_handle",
      binaryMessenger: engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    self.channel = channel
    transcriptStructureCursor.register(with: engine.binaryMessenger)
  }

  /// Brings the main window forward (Dock, menu items, a second launch).
  func showMainWindow() {
    guard let window = mainWindow else { return }
    show(window)
  }

  private func window(for call: FlutterMethodCall) -> NSWindow? {
    let live = Set(NSApp.windows.map(ObjectIdentifier.init))
    titlebarFaders = titlebarFaders.filter { live.contains($0.key) }

    guard let args = call.arguments as? [String: Any],
          let handle = (args["handle"] as? NSNumber)?.intValue,
          let pointer = UnsafeRawPointer(bitPattern: handle) else { return nil }
    return NSApp.windows.first { Unmanaged.passUnretained($0).toOpaque() == pointer }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let window = window(for: call) else {
      // Destroyed already, or never one of ours: nothing to do.
      result(nil)
      return
    }
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "hide":
      if window === mainWindow { transcriptStructureCursor.deactivateAll() }
      window.orderOut(nil)
      result(nil)

    case "show":
      show(window)
      result(nil)

    case "setAspectRatio":
      if let ratio = (args["aspectRatio"] as? NSNumber)?.doubleValue, ratio > 0 {
        window.contentAspectRatio = NSSize(width: ratio, height: 1)
      } else {
        // Assigning resize increments is what clears an aspect-ratio lock.
        window.contentResizeIncrements = NSSize(width: 1, height: 1)
      }
      result(nil)

    case "center":
      window.center()
      result(nil)

    case "startDrag":
      // Reply first: performDrag tracks the mouse until the button goes up.
      result(nil)
      if let event = NSApp.currentEvent,
         event.type == .leftMouseDown || event.type == .leftMouseDragged {
        window.performDrag(with: event)
      }

    case "registerMainWindow":
      registerMainWindow(window, startHidden: args["startHidden"] as? Bool ?? false)
      result(nil)

    case "setSkipTaskbar":
      // Windows only; macOS has no taskbar entry per window.
      result(nil)

    case "stylePlayerWindow":
      window.appearance = NSAppearance(named: .darkAqua)
      window.backgroundColor = .black
      window.collectionBehavior.insert(.fullScreenPrimary)
      // Video first: the picture fills the window and the title bar is laid
      // over it, transparent, fading with the player's controls.
      window.styleMask.insert(.fullSizeContentView)
      window.titlebarAppearsTransparent = true
      window.titleVisibility = .visible
      titlebarFaders[ObjectIdentifier(window)] = PlayerTitlebarFader(window: window)
      result(nil)

    case "setTitlebarVisible":
      let visible = args["visible"] as? Bool ?? true
      titlebarFaders[ObjectIdentifier(window)]?.setChromeVisible(visible)
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func show(_ window: NSWindow) {
    if window === mainWindow { keepHidden = nil }
    window.alphaValue = 1
    window.ignoresMouseEvents = false
    if window.isMiniaturized { window.deminiaturize(nil) }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

  /// The main window takes over what the template's `MainFlutterWindow` was:
  /// the target of the Dock, the menu and real full screen, drawn under a
  /// hidden title bar with the traffic lights over Flutter's toolbar.
  private func registerMainWindow(_ window: NSWindow, startHidden: Bool) {
    mainWindow = window
    window.styleMask.insert(.fullSizeContentView)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.collectionBehavior.insert(.fullScreenPrimary)
    window.center()
    transcriptStructureCursor.hostView = window.contentViewController?.view
    NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      self?.transcriptStructureCursor.deactivateAll()
    }
    if startHidden {
      keepHidden = HiddenAtLaunch(window: window)
    }
  }
}

/// Keeps a window off screen through its first frame. Flutter orders a
/// Dart-created window in once it has painted; a login-item launch, or one
/// that only opens a video, must not flash the main window.
final class HiddenAtLaunch: NSObject {
  private weak var window: NSWindow?
  private var observer: NSObjectProtocol?

  init(window: NSWindow) {
    self.window = window
    super.init()
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.orderOut(nil)
    observer = NotificationCenter.default.addObserver(
      forName: NSWindow.didChangeOcclusionStateNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      self?.hideIfShown()
    }
    // Belt and braces for platforms that order the window in silently.
    for delay in [0.25, 0.75, 1.5] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.hideIfShown()
      }
    }
  }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  private func hideIfShown() {
    guard let window, window.alphaValue == 0, window.isVisible else { return }
    window.orderOut(nil)
  }
}

/// Fades a player window's transparent title bar (traffic lights and title)
/// with the Flutter player's controls. It stays up while the pointer is over
/// it, and is left to the system in full screen.
final class PlayerTitlebarFader: NSObject {
  private weak var window: NSWindow?
  private var chromeVisible = true
  private var hovering = false
  private var trackingArea: NSTrackingArea?
  private var observers: [NSObjectProtocol] = []

  init(window: NSWindow) {
    self.window = window
    super.init()
    installTracking()
    let center = NotificationCenter.default
    for name in [NSWindow.willEnterFullScreenNotification,
                 NSWindow.didExitFullScreenNotification] {
      observers.append(center.addObserver(
        forName: name, object: window, queue: .main
      ) { [weak self] _ in
        self?.installTracking()
        self?.apply(animated: false)
      })
    }
  }

  deinit {
    observers.forEach(NotificationCenter.default.removeObserver)
  }

  private var titlebarView: NSView? {
    window?.standardWindowButton(.closeButton)?.superview
  }

  private var isFullScreen: Bool {
    window?.styleMask.contains(.fullScreen) ?? false
  }

  private func installTracking() {
    guard let view = titlebarView else { return }
    if let trackingArea { view.removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    view.addTrackingArea(area)
    trackingArea = area
  }

  func setChromeVisible(_ visible: Bool) {
    guard visible != chromeVisible else { return }
    chromeVisible = visible
    apply(animated: true)
  }

  @objc func mouseEntered(with event: NSEvent) {
    hovering = true
    apply(animated: true)
  }

  @objc func mouseExited(with event: NSEvent) {
    hovering = false
    apply(animated: true)
  }

  private func apply(animated: Bool) {
    guard let view = titlebarView else { return }
    let alpha: CGFloat = isFullScreen || chromeVisible || hovering ? 1 : 0
    guard animated else {
      view.alphaValue = alpha
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      view.animator().alphaValue = alpha
    }
  }
}

final class TranscriptStructureCursorController {
  enum Kind: String {
    case split
    case merge
  }

  private static let channelName =
    "app.capyvibe.listenook/transcript_structure_cursor"
  weak var hostView: NSView?
  private var channel: FlutterMethodChannel?
  private(set) var activeSession: Int?
  private(set) var activeKind: Kind?
  private var activeCursor: NSCursor?
  private lazy var splitCursor = makeCursor(kind: .split)
  private lazy var mergeCursor = makeCursor(kind: .merge)

  init(hostView: NSView? = nil) {
    self.hostView = hostView
  }

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      switch call.method {
      case "activate":
        guard
          let arguments = call.arguments as? [String: Any],
          let rawKind = arguments["kind"] as? String,
          let kind = Kind(rawValue: rawKind),
          let session = arguments["session"] as? Int
        else {
          result(FlutterError(
            code: "invalid_cursor_arguments",
            message: "A cursor kind and session are required.",
            details: nil
          ))
          return
        }
        self.activate(kind: kind, session: session)
        result(nil)
      case "deactivate":
        guard
          let arguments = call.arguments as? [String: Any],
          let session = arguments["session"] as? Int
        else {
          result(FlutterError(
            code: "invalid_cursor_arguments",
            message: "A cursor session is required.",
            details: nil
          ))
          return
        }
        self.deactivate(session: session)
        result(nil)
      case "deactivateAll":
        self.deactivateAll()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  func activate(kind: Kind, session: Int) {
    activeSession = session
    activeKind = kind
    activeCursor = kind == .split ? splitCursor : mergeCursor
    if let activeCursor {
      recordFlutterCursor(activeCursor)
    }
    activeCursor?.set()
  }

  func deactivate(session: Int) {
    guard activeSession == session else { return }
    // Clearing custom ownership must not write a fallback cursor. Flutter may
    // already have installed a newer I-beam, forbidden, or basic cursor.
    activeSession = nil
    activeKind = nil
    activeCursor = nil
  }

  func deactivateAll() {
    let previous = activeCursor
    let current = NSCursor.current
    activeSession = nil
    activeKind = nil
    activeCursor = nil
    if previous != nil {
      // Keep FlutterView's restoration cache in sync without writing an actual
      // fallback cursor. This preserves newer I-beam/basic/forbidden writes.
      recordFlutterCursor(current === previous ? NSCursor.arrow : current)
    }
  }

  func cursor(for kind: Kind) -> NSCursor {
    kind == .split ? splitCursor : mergeCursor
  }

  private func recordFlutterCursor(_ cursor: NSCursor) {
    let selector = NSSelectorFromString("didUpdateMouseCursor:")
    guard let hostView, hostView.responds(to: selector) else { return }
    hostView.perform(selector, with: cursor)
  }

  private func makeCursor(kind: Kind) -> NSCursor {
    let size = NSSize(width: 24, height: 24)
    let image = NSImage(size: size)
    for scale in [1, 2] {
      guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width) * scale,
        pixelsHigh: Int(size.height) * scale,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ), let context = NSGraphicsContext(bitmapImageRep: representation) else {
        continue
      }
      representation.size = size
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = context
      context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
      drawGlyph(kind: kind)
      NSGraphicsContext.restoreGraphicsState()
      image.addRepresentation(representation)
    }
    image.isTemplate = false
    return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
  }

  private func drawGlyph(kind: Kind) {
    let outline = NSBezierPath()
    outline.lineWidth = 4
    outline.lineCapStyle = .round
    outline.lineJoinStyle = .round
    appendGlyph(kind: kind, to: outline)
    NSColor.white.setStroke()
    outline.stroke()

    let foreground = NSBezierPath()
    foreground.lineWidth = 2
    foreground.lineCapStyle = .round
    foreground.lineJoinStyle = .round
    appendGlyph(kind: kind, to: foreground)
    NSColor.black.setStroke()
    foreground.stroke()
  }

  private func appendGlyph(kind: Kind, to path: NSBezierPath) {
    switch kind {
    case .split:
      path.move(to: NSPoint(x: 12, y: 3))
      path.line(to: NSPoint(x: 12, y: 21))
      path.move(to: NSPoint(x: 9, y: 8))
      path.line(to: NSPoint(x: 5, y: 8))
      path.line(to: NSPoint(x: 7, y: 6))
      path.move(to: NSPoint(x: 15, y: 16))
      path.line(to: NSPoint(x: 19, y: 16))
      path.line(to: NSPoint(x: 17, y: 18))
    case .merge:
      path.move(to: NSPoint(x: 12, y: 3))
      path.line(to: NSPoint(x: 12, y: 10))
      path.move(to: NSPoint(x: 8, y: 7))
      path.line(to: NSPoint(x: 12, y: 11))
      path.line(to: NSPoint(x: 16, y: 7))
      path.move(to: NSPoint(x: 12, y: 21))
      path.line(to: NSPoint(x: 12, y: 14))
      path.move(to: NSPoint(x: 8, y: 17))
      path.line(to: NSPoint(x: 12, y: 13))
      path.line(to: NSPoint(x: 16, y: 17))
    }
  }
}
