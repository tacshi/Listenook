import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'signed macOS releases are notarized and stapled before distribution',
    () async {
      final source = await File(
        '${Directory.current.path}/scripts/build-macos.sh',
      ).readAsString();

      expect(
        source,
        contains(r'NOTARY_PROFILE="${MEOWSTT_NOTARY_PROFILE:-MeowSTT}"'),
        reason: 'A stored `MeowSTT` notarytool profile should work by default.',
      );
      expect(source, contains(r'xcrun stapler staple "$APP"'));
      expect(source, contains(r'xcrun stapler validate "$APP"'));
      expect(source, contains(r'codesign "${DMG_SIGN_ARGS[@]}" "$DMG"'));
      expect(source, contains(r'xcrun stapler staple "$DMG"'));
      expect(source, contains(r'xcrun stapler validate "$DMG"'));
      expect(source, contains(r'ditto -c -k --keepParent "$APP" "$APP_ZIP"'));

      final appStaple = source.indexOf(r'xcrun stapler staple "$APP"');
      final dmgSign = source.indexOf(r'codesign "${DMG_SIGN_ARGS[@]}" "$DMG"');
      final dmgSubmit = source.indexOf(r'xcrun notarytool submit "$DMG"');

      expect(appStaple, greaterThanOrEqualTo(0));
      expect(dmgSign, greaterThanOrEqualTo(0));
      expect(dmgSubmit, greaterThan(dmgSign));
      expect(appStaple, greaterThan(dmgSubmit));
    },
    skip: !Platform.isMacOS,
  );
}
