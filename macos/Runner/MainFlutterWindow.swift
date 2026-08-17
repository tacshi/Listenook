import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private let applicationChannels = ApplicationChannels()

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    applicationChannels.register(
      with: flutterViewController.engine.binaryMessenger
    )

    super.awakeFromNib()
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
