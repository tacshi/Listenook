import Flutter
import UIKit

/// The iPad menu bar and its hold-⌘ shortcut list. Each command goes to Dart
/// over the navigation channel (lib/ui/app_shell.dart), like the macOS menu.
/// Titles come from Dart so they follow the language chosen in the app.
///
/// ⌘↩ is left to Flutter: it also saves edits and checks dictation, and a
/// key command would take it from text fields.
final class KeyCommandMenu {
  static let shared = KeyCommandMenu()

  private var channel: FlutterMethodChannel?
  private var titles: [String: String] = [
    "go": "Go",
    "podcast": "Podcasts",
    "workspace": "Workspace",
    "library": "Library",
    "inbox": "Inbox",
    "settings": "Settings…",
    "add_files": "Add Media or Subtitles…",
    "watch_video": "Watch a Video…",
    "toggle_sidebar": "Show or Hide Sidebar",
  ]

  func attach(to messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(
      name: "app.capyvibe.listenook/navigation",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "setMenuTitles",
            let titles = call.arguments as? [String: String]
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.titles.merge(titles) { _, new in new }
      UIMenuSystem.main.setNeedsRebuild()
      result(nil)
    }
    self.channel = channel
    return channel
  }

  func send(_ method: String, _ arguments: Any? = nil) {
    channel?.invokeMethod(method, arguments: arguments)
  }

  func build(with builder: UIMenuBuilder) {
    guard builder.system == .main else { return }
    func command(_ key: String, _ input: String, _ flags: UIKeyModifierFlags, _ action: Selector)
      -> UIKeyCommand
    {
      UIKeyCommand(title: titles[key] ?? key, action: action, input: input, modifierFlags: flags)
    }
    builder.insertChild(
      UIMenu(options: .displayInline, children: [
        command("add_files", "o", .command, #selector(AppDelegate.addFilesCommand)),
        command("watch_video", "o", [.command, .shift], #selector(AppDelegate.watchVideoCommand)),
      ]),
      atStartOfMenu: .file
    )
    builder.insertChild(
      UIMenu(options: .displayInline, children: [
        command("toggle_sidebar", "b", .command, #selector(AppDelegate.toggleSidebarCommand)),
      ]),
      atStartOfMenu: .view
    )
    builder.insertSibling(
      UIMenu(
        title: titles["go"] ?? "Go",
        identifier: UIMenu.Identifier("app.capyvibe.listenook.go"),
        children: [
          command("podcast", "1", .command, #selector(AppDelegate.showPodcastCommand)),
          command("workspace", "2", .command, #selector(AppDelegate.showWorkspaceCommand)),
          command("library", "3", .command, #selector(AppDelegate.showLibraryCommand)),
          command("inbox", "i", .command, #selector(AppDelegate.showInboxCommand)),
        ]
      ),
      afterMenu: .view
    )
    builder.replaceChildren(ofMenu: .preferences) { _ in
      [command("settings", ",", .command, #selector(AppDelegate.showSettingsCommand))]
    }
  }
}

extension AppDelegate {
  override func buildMenu(with builder: UIMenuBuilder) {
    super.buildMenu(with: builder)
    KeyCommandMenu.shared.build(with: builder)
  }

  @objc func showPodcastCommand() { KeyCommandMenu.shared.send("showDestination", "podcast") }
  @objc func showWorkspaceCommand() { KeyCommandMenu.shared.send("showDestination", "workspace") }
  @objc func showLibraryCommand() { KeyCommandMenu.shared.send("showDestination", "library") }
  @objc func showInboxCommand() { KeyCommandMenu.shared.send("showInbox") }
  @objc func showSettingsCommand() { KeyCommandMenu.shared.send("showSettings") }
  @objc func addFilesCommand() { KeyCommandMenu.shared.send("addFiles") }
  @objc func watchVideoCommand() { KeyCommandMenu.shared.send("watchVideo") }
  @objc func toggleSidebarCommand() { KeyCommandMenu.shared.send("toggleSidebar") }
}
