import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:listenook/main.dart';
import 'package:listenook/data/app_data_migration.dart';
import 'package:listenook/data/migrating_secure_value.dart';

void main() {
  testWidgets('startup paints a visible loading screen before initialization', (
    tester,
  ) async {
    final application = Completer<Widget>();
    await tester.pumpWidget(
      ListenookBootstrap(application: application.future),
    );

    expect(find.text('Starting Listenook…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    application.complete(const MaterialApp(home: Text('Application ready')));
    await tester.pumpAndSettle();
    expect(find.text('Application ready'), findsOneWidget);
  });

  testWidgets('startup failure replaces the loader with a visible error', (
    tester,
  ) async {
    final application = Completer<Widget>();
    await tester.pumpWidget(
      ListenookBootstrap(application: application.future),
    );

    application.completeError(StateError('bootstrap failed'));
    await tester.pumpAndSettle();
    expect(find.textContaining('could not start'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
  testWidgets('migration failure can retry before the app starts', (
    tester,
  ) async {
    final initial = Completer<Widget>();
    var restarted = false;
    await tester.pumpWidget(
      ListenookBootstrap(
        application: initial.future,
        restart: () async {
          restarted = true;
          return const MaterialApp(home: Text('Recovered'));
        },
      ),
    );
    initial.completeError(
      const AppMigrationException('migration_legacy_running'),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Quit MeowSTT'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(restarted, isTrue);
    expect(find.text('Recovered'), findsOneWidget);
  });

  testWidgets('Chinese startup uses the localized name', (tester) async {
    final initial = Completer<Widget>();
    final locale = ValueNotifier(const Locale('zh', 'CN'));
    addTearDown(locale.dispose);
    await tester.pumpWidget(
      ListenookBootstrap(application: initial.future, locale: locale),
    );
    expect(find.text('正在启动聆页…'), findsOneWidget);
    initial.complete(const MaterialApp(home: Text('Ready')));
    await tester.pumpAndSettle();
  });

  testWidgets('denied credentials can be entered without starting workers', (
    tester,
  ) async {
    final initial = Completer<Widget>();
    String? saved;
    var started = false;
    await tester.pumpWidget(
      ListenookBootstrap(
        application: initial.future,
        restart: () async {
          started = true;
          return const MaterialApp(home: Text('Ready'));
        },
      ),
    );
    initial.completeError(
      CredentialMigrationException([
        CredentialMigrationTarget('Soniox', () async {}, (key) async {
          saved = key;
        }),
      ]),
    );
    await tester.pumpAndSettle();
    expect(started, isFalse);
    await tester.tap(find.text('Enter API keys again'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).obscureText,
      isTrue,
    );
    await tester.enterText(find.byType(TextField), 'replacement-test-key');
    await tester.tap(find.text('Save and continue'));
    await tester.pumpAndSettle();
    expect(saved, 'replacement-test-key');
    expect(started, isTrue);
  });
}
