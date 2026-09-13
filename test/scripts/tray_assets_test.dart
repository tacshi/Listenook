import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

void main() {
  test('desktop tray assets are included in the Flutter asset bundle', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();

    expect(pubspec, contains('    - assets/branding/tray/'));
  });

  test('macOS tray template has native alpha-only 1x and 2x assets', () {
    final oneX = image.decodePng(
      File('assets/branding/tray/listenook-tray-template.png').readAsBytesSync(),
    )!;
    final twoX = image.decodePng(
      File(
        'assets/branding/tray/listenook-tray-template@2x.png',
      ).readAsBytesSync(),
    )!;

    expect((oneX.width, oneX.height), (18, 18));
    expect((twoX.width, twoX.height), (36, 36));
    for (final pixel in twoX) {
      if (pixel.a == 0) continue;
      expect(pixel.r, 0);
      expect(pixel.g, 0);
      expect(pixel.b, 0);
    }
  });

  test('Windows tray ICO contains the required transparent native sizes', () {
    final bytes = File(
      'assets/branding/tray/listenook-tray.ico',
    ).readAsBytesSync();
    final data = ByteData.sublistView(bytes);
    expect(data.getUint16(0, Endian.little), 0);
    expect(data.getUint16(2, Endian.little), 1);
    final count = data.getUint16(4, Endian.little);
    expect(count, 8);
    final sizes = <int>{};
    for (var index = 0; index < count; index++) {
      final width = bytes[6 + index * 16];
      final height = bytes[7 + index * 16];
      expect(height == 0 ? 256 : height, width == 0 ? 256 : width);
      sizes.add(width == 0 ? 256 : width);
    }
    expect(sizes, containsAll(<int>[16, 20, 24, 32, 40, 48, 64, 256]));

    final preview = image.decodePng(
      File(
        'assets/branding/tray/listenook-tray-windows-preview.png',
      ).readAsBytesSync(),
    )!;
    expect(preview.any((pixel) => pixel.a == 0), isTrue);
    expect(
      preview.any(
        (pixel) => pixel.a > 200 && pixel.r > 100 && pixel.b > pixel.r,
      ),
      isTrue,
    );
  });
}
