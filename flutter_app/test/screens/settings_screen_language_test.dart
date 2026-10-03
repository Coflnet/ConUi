// Widget tests for SettingsScreen's Language section: picking an app
// language / a recording language persists the choice (SharedPreferences)
// and is reflected immediately in the tile's subtitle.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:relationship_manager/backup/backup_service.dart';
import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/screens/settings_screen.dart';
import 'package:relationship_manager/services/app_settings_service.dart';
import 'package:relationship_manager/services/auth_service.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/recording_file_store_native.dart';
import 'package:relationship_manager/services/sync_service.dart';

import '../support/test_database.dart';

Widget _wrap({
  required DatabaseService db,
  required BackupService backupService,
  required AppSettingsService appSettings,
}) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: const [Locale('en'), Locale('de')],
    home: MultiProvider(
      providers: [
        ChangeNotifierProvider<DatabaseService>.value(value: db),
        ChangeNotifierProvider<AuthService>(create: (_) => AuthService()),
        ChangeNotifierProvider<SyncService>(create: (_) => SyncService(db, AuthService())),
        ChangeNotifierProvider<AppSettingsService>.value(value: appSettings),
      ],
      child: SettingsScreen(backupService: backupService),
    ),
  );
}

Future<void> _settle(WidgetTester tester, {int rounds = 40}) async {
  for (var i = 0; i < rounds; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
}

void main() {
  late Directory tempDir;
  late DatabaseService db;
  late BackupService backupService;
  late AppSettingsService appSettings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('settings_language_test');
    db = createTestDatabaseService();
    await db.initialize();
    backupService = BackupService(
      databaseService: db,
      recordingStore: NativeRecordingFileStore(baseDirectory: tempDir),
    );
    appSettings = AppSettingsService();
    await appSettings.initialize();
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('starts on System / Automatic and shows both language tiles',
      (tester) async {
    await tester.pumpWidget(
        _wrap(db: db, backupService: backupService, appSettings: appSettings));
    await _settle(tester);

    expect(find.text('App language'), findsOneWidget);
    expect(find.text('System'), findsOneWidget);
    expect(find.text('Language of recordings'), findsOneWidget);
    expect(find.text('Automatic'), findsOneWidget);
  });

  testWidgets(
      'picking Deutsch as the app language persists it and updates the subtitle',
      (tester) async {
    await tester.pumpWidget(
        _wrap(db: db, backupService: backupService, appSettings: appSettings));
    await _settle(tester);

    await tester.tap(find.text('App language'));
    await tester.pumpAndSettle();
    // Two "Deutsch" radio options exist once the dialog is open (one per
    // language tile's own dialog would collide, but only the app-language
    // dialog is open right now) - the dialog's own RadioListTile.
    await tester.tap(find.widgetWithText(RadioListTile<Locale?>, 'Deutsch'));
    await tester.pumpAndSettle();

    expect(appSettings.languageOverride, const Locale('de'));
    expect(find.text('Deutsch'), findsOneWidget,
        reason: 'the App language tile\'s subtitle must now read Deutsch');

    // Persisted: a fresh AppSettingsService reading the same
    // SharedPreferences must see the same override.
    final reloaded = AppSettingsService();
    await reloaded.initialize();
    expect(reloaded.languageOverride, const Locale('de'));
  });

  testWidgets(
      'picking English for the recording language persists it independently',
      (tester) async {
    await tester.pumpWidget(
        _wrap(db: db, backupService: backupService, appSettings: appSettings));
    await _settle(tester);

    await tester.tap(find.text('Language of recordings'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(RadioListTile<String?>, 'English'));
    await tester.pumpAndSettle();

    expect(appSettings.recordingLanguageOverride, 'en');
    // The app language itself must be untouched by this - the two
    // settings are independent.
    expect(appSettings.languageOverride, isNull);

    final reloaded = AppSettingsService();
    await reloaded.initialize();
    expect(reloaded.recordingLanguageOverride, 'en');
  });
  testWidgets('offline sync explains account requirement instead of success',
      (tester) async {
    await tester.pumpWidget(
        _wrap(db: db, backupService: backupService, appSettings: appSettings));
    await _settle(tester);
    await tester.tap(find.text('Force Sync'));
    await _settle(tester);
    expect(
        find.text(
            'Sync requires an account. Your stories remain saved on this device.'),
        findsOneWidget);
    expect(find.text('Sync completed successfully'), findsNothing);
  });
}
