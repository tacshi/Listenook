import Flutter
import UIKit
import UniformTypeIdentifiers

class SceneDelegate: FlutterSceneDelegate {
  private let dropDelegate = FileDropDelegate()

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    // Files dragged in from other apps (iPad) go to the Inbox like files
    // opened from them.
    window?.rootViewController?.view.addInteraction(
      UIDropInteraction(delegate: dropDelegate)
    )
    // Launched by "Open in Listenook" or "Copy to Listenook".
    OpenFileInbox.shared.receive(urls: connectionOptions.urlContexts.map(\.url))
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: URLContexts)
    OpenFileInbox.shared.receive(urls: URLContexts.map(\.url))
  }
}

/// Accepts audio, video and subtitle files dropped on the app.
final class FileDropDelegate: NSObject, UIDropInteractionDelegate {
  private static let types = [
    UTType.audiovisualContent.identifier,
    UTType.plainText.identifier,
  ]

  func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
    session.hasItemsConforming(toTypeIdentifiers: Self.types)
  }

  func dropInteraction(
    _ interaction: UIDropInteraction,
    sessionDidUpdate session: UIDropSession
  ) -> UIDropProposal {
    UIDropProposal(operation: .copy)
  }

  func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
    let group = DispatchGroup()
    var paths: [String] = []
    let lock = NSLock()
    for item in session.items {
      let provider = item.itemProvider
      guard let type = provider.registeredTypeIdentifiers.first(where: { identifier in
        Self.types.contains { UTType(identifier)?.conforms(to: UTType($0)!) == true }
      }) else { continue }
      group.enter()
      // The file is deleted once the handler returns, so copy it right away.
      provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
        defer { group.leave() }
        guard let url, let copy = IncomingFiles.copy(url, name: provider.suggestedName)
        else { return }
        lock.lock()
        paths.append(copy)
        lock.unlock()
      }
    }
    group.notify(queue: .main) {
      OpenFileInbox.shared.deliver(paths)
    }
  }
}
