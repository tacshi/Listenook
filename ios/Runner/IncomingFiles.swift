import Flutter
import UIKit
import UniformTypeIdentifiers

/// Files other apps hand over are only readable for a moment, so they are
/// copied into `tmp/Incoming` first; Dart then moves them into its own
/// storage (lib/data/managed_media_store.dart).
enum IncomingFiles {
  static var folder: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "Incoming",
      isDirectory: true
    )
  }

  /// Copies [url] into a new folder under Incoming and returns the copy's
  /// path. A folder keeps only the files whose extension is in [extensions].
  static func copy(_ url: URL, name: String? = nil, extensions: Set<String>? = nil) -> String? {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let destinationFolder = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
    var fileName = url.lastPathComponent
    if let name, !name.isEmpty {
      // Dropped items carry a temporary name; keep the original's.
      let ext = url.pathExtension
      fileName = ext.isEmpty || name.hasSuffix(".\(ext)") ? name : "\(name).\(ext)"
    }
    let destination = destinationFolder.appendingPathComponent(fileName)
    var copied: String?
    var coordinationError: NSError?
    NSFileCoordinator().coordinate(
      readingItemAt: url,
      options: .withoutChanges,
      error: &coordinationError
    ) { readable in
      do {
        try FileManager.default.createDirectory(
          at: destinationFolder,
          withIntermediateDirectories: true
        )
        if let extensions, (try? readable.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
          try copyFolder(readable, to: destination, extensions: extensions)
        } else {
          try FileManager.default.copyItem(at: readable, to: destination)
        }
        copied = destination.path
      } catch {
        try? FileManager.default.removeItem(at: destinationFolder)
      }
    }
    return copied
  }

  private static func copyFolder(_ source: URL, to destination: URL, extensions: Set<String>) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: destination, withIntermediateDirectories: true)
    guard let items = manager.enumerator(
      at: source,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return }
    let base = source.standardizedFileURL.path
    for case let item as URL in items {
      guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
            extensions.contains(item.pathExtension.lowercased())
      else { continue }
      let relative = String(item.standardizedFileURL.path.dropFirst(base.count))
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      let target = destination.appendingPathComponent(relative)
      try manager.createDirectory(
        at: target.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try manager.copyItem(at: item, to: target)
    }
  }
}

/// Holds files opened from other apps until Dart takes them, so a file that
/// launches the app is not lost while Flutter starts. The same channel and
/// methods as the macOS runner's.
final class OpenFileInbox {
  static let shared = OpenFileInbox()

  private var pending: [String] = []
  private var channel: FlutterMethodChannel?

  func attach(to messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(
      name: "app.capyvibe.listenook/open_files",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "launchedForFiles":
        // iOS always shows the app; the files simply queue.
        result(false)
      case "takePendingOpenFiles":
        result(self?.pending ?? [])
        self?.pending.removeAll()
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
    return channel
  }

  func receive(urls: [URL]) {
    let files = urls.filter(\.isFileURL)
    guard !files.isEmpty else { return }
    DispatchQueue.global(qos: .userInitiated).async {
      let copies = files.compactMap { IncomingFiles.copy($0) }
      DispatchQueue.main.async { self.deliver(copies) }
    }
  }

  func deliver(_ paths: [String]) {
    guard !paths.isEmpty else { return }
    pending.append(contentsOf: paths)
    channel?.invokeMethod("openFilesAvailable", arguments: nil)
  }
}

/// Folder import and exports, which the file_selector plugin does not offer
/// on iOS.
final class FilesChannel: NSObject, UIDocumentPickerDelegate {
  private static let shared = FilesChannel()
  private var pendingFolder: (result: FlutterResult, extensions: Set<String>)?

  static func register(with messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(
      name: "app.capyvibe.listenook/files",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      let arguments = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "pickFolder":
        let extensions = Set((arguments["extensions"] as? [String] ?? []).map { $0.lowercased() })
        shared.pickFolder(extensions: extensions, result: result)
      case "share":
        shared.share(
          paths: arguments["paths"] as? [String] ?? [],
          anchor: arguments["anchor"] as? [Double],
          result: result
        )
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    return channel
  }

  private static var presenter: UIViewController? {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
      ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    var controller = scene?.keyWindow?.rootViewController
    while let presented = controller?.presentedViewController { controller = presented }
    return controller
  }

  private func pickFolder(extensions: Set<String>, result: @escaping FlutterResult) {
    guard pendingFolder == nil, let presenter = Self.presenter else {
      result(nil)
      return
    }
    pendingFolder = (result, extensions)
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
    picker.delegate = self
    picker.allowsMultipleSelection = false
    presenter.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let pending = pendingFolder else { return }
    pendingFolder = nil
    guard let url = urls.first else {
      pending.result(nil)
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let copy = IncomingFiles.copy(url, extensions: pending.extensions)
      DispatchQueue.main.async { pending.result(copy) }
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pendingFolder?.result(nil)
    pendingFolder = nil
  }

  /// The share sheet, which includes "Save to Files". Returns whether the
  /// user completed an action. iPad needs [anchor] (x, y, width, height in
  /// points) to point the popover at the button that opened it.
  private func share(paths: [String], anchor: [Double]?, result: @escaping FlutterResult) {
    guard !paths.isEmpty, let presenter = Self.presenter else {
      result(false)
      return
    }
    let sheet = UIActivityViewController(
      activityItems: paths.map { URL(fileURLWithPath: $0) },
      applicationActivities: nil
    )
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = presenter.view
      if let anchor, anchor.count == 4 {
        popover.sourceRect = CGRect(x: anchor[0], y: anchor[1], width: anchor[2], height: anchor[3])
      } else {
        let bounds = presenter.view.bounds
        popover.sourceRect = CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0)
        popover.permittedArrowDirections = []
      }
    }
    sheet.completionWithItemsHandler = { _, completed, _, _ in
      result(completed)
    }
    presenter.present(sheet, animated: true)
  }
}
