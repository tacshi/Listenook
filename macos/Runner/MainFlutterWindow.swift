import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private let applicationChannels = ApplicationChannels()
  private var transcriptStructureCursor: TranscriptStructureCursorController?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    applicationChannels.register(
      with: flutterViewController.engine.binaryMessenger
    )
    let transcriptStructureCursor = TranscriptStructureCursorController(
      hostView: flutterViewController.view
    )
    transcriptStructureCursor.register(
      with: flutterViewController.engine.binaryMessenger
    )
    self.transcriptStructureCursor = transcriptStructureCursor

    super.awakeFromNib()
  }

  override func sendEvent(_ event: NSEvent) {
    super.sendEvent(event)
    if event.type == .mouseExited {
      transcriptStructureCursor?.deactivateAll()
    }
  }

  override func resignKey() {
    transcriptStructureCursor?.deactivateAll()
    super.resignKey()
  }

  override func order(
    _ place: NSWindow.OrderingMode,
    relativeTo otherWindowNumber: Int
  ) {
    let previousAnimationBehavior = animationBehavior
    animationBehavior = .none
    super.order(place, relativeTo: otherWindowNumber)
    hiddenWindowAtLaunch()
    animationBehavior = previousAnimationBehavior
  }
}

final class TranscriptStructureCursorController {
  enum Kind: String {
    case split
    case merge
  }

  private static let channelName =
    "app.capyvibe.listenook/transcript_structure_cursor"
  private weak var hostView: NSView?
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
