import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meow_stt/main.dart';

void main() {
  testWidgets('startup paints a visible loading screen before initialization', (
    tester,
  ) async {
    final application = Completer<Widget>();
    await tester.pumpWidget(MeowSttBootstrap(application: application.future));

    expect(find.text('Starting MeowSTT…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    application.complete(const MaterialApp(home: Text('Application ready')));
    await tester.pumpAndSettle();
    expect(find.text('Application ready'), findsOneWidget);
  });

  testWidgets('startup failure replaces the loader with a visible error', (
    tester,
  ) async {
    final application = Completer<Widget>();
    await tester.pumpWidget(MeowSttBootstrap(application: application.future));

    application.completeError(StateError('bootstrap failed'));
    await tester.pumpAndSettle();
    expect(find.textContaining('could not start'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
