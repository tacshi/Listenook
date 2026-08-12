import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'debug signing prefers the release identity and retains ad-hoc fallback',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'meowstt-debug-signing-',
      );
      addTearDown(() => root.delete(recursive: true));
      await Directory(
        '${root.path}/build/macos/Build/Products/Release/MeowSTT.app',
      ).create(recursive: true);
      final helper = File('${Directory.current.path}/scripts/macos-signing.sh');
      final command =
          '''
unset MEOWSTT_MAC_DEBUG_SIGN_IDENTITY MEOWSTT_MAC_SIGN_IDENTITY DEVELOPER_ID_APPLICATION
security() {
  printf '%s\n' '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Other (OTHERTEAM)"' '  2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Developer ID Application: Release (TEAM123)"'
}
codesign() {
  printf '%s\n' 'TeamIdentifier=TEAM123' >&2
}
source "${helper.path}"
resolve_meowstt_debug_sign_identity "${root.path}"
MEOWSTT_MAC_SIGN_IDENTITY='Developer ID Application: Configured (CONFIGTEAM)'
resolve_meowstt_debug_sign_identity "${root.path}"
unset MEOWSTT_MAC_SIGN_IDENTITY
security() {
  printf '%s\n' '     0 valid identities found'
}
resolve_meowstt_debug_sign_identity "${root.path}"
''';
      final result = await Process.run('bash', ['-c', command]);

      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout.toString().trim().split('\n'), [
        'Developer ID Application: Release (TEAM123)',
        'Developer ID Application: Configured (CONFIGTEAM)',
        '-',
      ]);

      final buildSource = await File(
        '${Directory.current.path}/scripts/build-macos.sh',
      ).readAsString();
      expect(buildSource, contains('resolve_meowstt_debug_sign_identity'));
      expect(buildSource, contains('meowstt_sign_app_bundle'));
      expect(buildSource, contains('retrying the debug app ad-hoc'));
    },
    skip: !Platform.isMacOS,
  );
}
