/// Rewrites absolute paths inside stored JSON so they survive iOS moving the
/// app's data container (its path contains a UUID that changes when the app
/// is reinstalled or restored).
///
/// Works on the encoded JSON text: a string value that starts with the
/// container root is stored as `@container/…` and expanded again on load.
/// Paths saved by an earlier container are moved onto the current one.
class ContainerPathCodec {
  const ContainerPathCodec(this.root);

  /// No rewriting: desktop paths stay where the user put the files.
  const ContainerPathCodec.none() : root = null;

  static const marker = '@container';

  /// The app's data container, without a trailing slash.
  final String? root;

  static final _previousContainer = RegExp(
    r'"(?:/private)?/var/mobile/Containers/Data/Application/'
    r'[0-9A-Fa-f-]{36}/',
  );

  String encode(String json) {
    final root = this.root;
    if (root == null) return json;
    final privateRoot = root.startsWith('/private/') ? root : '/private$root';
    final publicRoot = root.startsWith('/private/')
        ? root.substring('/private'.length)
        : root;
    return json
        .replaceAll('"$privateRoot/', '"$marker/')
        .replaceAll('"$publicRoot/', '"$marker/');
  }

  String decode(String json) {
    final root = this.root;
    if (root == null) return json;
    return json
        .replaceAll('"$marker/', '"$root/')
        .replaceAll(_previousContainer, '"$root/');
  }
}
