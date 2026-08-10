import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meow_stt/data/local_repositories.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS Keychain can securely round-trip a credential', (
    tester,
  ) async {
    final store = SecureCredentialStore(
      storageKey: 'app.meowstt.desktop.integration_test_key',
    );
    const value = 'meowstt-keychain-round-trip';

    addTearDown(store.deleteApiKey);
    await store.writeApiKey(value);

    expect(await store.readApiKey(), value);
  });
}
