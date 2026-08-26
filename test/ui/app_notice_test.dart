import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/ui/app_notice.dart';

void main() {
  testWidgets('app notices are compact, floating, and dismissible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(dismissAppNotice);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppNotice(
                context,
                message: 'Saved',
                tone: AppNoticeTone.success,
              ),
              child: const Text('Show'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Show'));
    await tester.pumpAndSettle();

    final notice = find.byKey(const Key('app-notice'));
    expect(notice, findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    final rect = tester.getRect(notice);
    expect(rect.width, lessThanOrEqualTo(360));
    expect(rect.right, 784);
    expect(rect.bottom, 684);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    expect(notice, findsNothing);
  });
}
