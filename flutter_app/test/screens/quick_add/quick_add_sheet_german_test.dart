// German-locale rendering tests for the quick add sheet and the recorder
// state/failure messages it (and the add/edit story form) shares - see the
// l10n work package's requirement to add German rendering tests for these
// specifically. Mirrors quick_add_sheet_test.dart's setup but fixes the
// locale to German and asserts on the German strings instead of the
// English ones.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/screens/quick_add/quick_add_sheet.dart';
import 'package:relationship_manager/services/audio_capture.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/recorder_controller.dart';
import 'package:relationship_manager/services/recording_file_store_native.dart';
import 'package:relationship_manager/services/transcription_client.dart';

import '../../support/fake_audio_capture.dart';
import '../../support/test_database.dart';

Widget _wrapDe(DatabaseService db, Widget child) {
  return MaterialApp(
    locale: const Locale('de'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: ChangeNotifierProvider<DatabaseService>.value(
      value: db,
      child: Scaffold(body: child),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 2; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('quick_add_sheet_german_test');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  RecorderController buildRecorder(DatabaseService db, FakeAudioCapture capture) {
    return RecorderController(
      audioCapture: capture,
      fileStore: NativeRecordingFileStore(baseDirectory: tempDir),
      database: db,
      transcriptionClient: TranscriptionClient(baseUrl: 'https://api.example.com', getToken: () => null),
      segmentDuration: const Duration(milliseconds: 100),
      backoff: (_) => Duration.zero,
    );
  }

  testWidgets('renders its labels in German', (tester) async {
    late DatabaseService db;
    await tester.runAsync(() async {
      db = createTestDatabaseService();
      await db.initialize();
    });
    final capture = FakeAudioCapture();
    final recorder = buildRecorder(db, capture);
    final position = ValueNotifier<LatLng>(const LatLng(10, 10));

    await tester.pumpWidget(
        _wrapDe(db, QuickAddSheet(position: position, recorderController: recorder)));
    await _settle(tester);

    expect(find.text('Neue Geschichte'), findsOneWidget);
    expect(find.text('Personen in dieser Geschichte'), findsOneWidget);
    expect(find.text('Wann war das?'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Was ist hier passiert?'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Geschichte speichern'), findsOneWidget);
    expect(find.bySemanticsLabel('Aufnahme starten'), findsOneWidget);
  });

  testWidgets('shows the German microphone-permission-denied message', (tester) async {
    late DatabaseService db;
    await tester.runAsync(() async {
      db = createTestDatabaseService();
      await db.initialize();
    });
    final capture = FakeAudioCapture()
      ..failureOnStart = AudioCaptureException(AudioCaptureFailureReason.permissionDenied, 'denied');
    final recorder = buildRecorder(db, capture);
    final position = ValueNotifier<LatLng>(const LatLng(10, 10));

    await tester.pumpWidget(
        _wrapDe(db, QuickAddSheet(position: position, recorderController: recorder)));
    await _settle(tester);

    await tester.runAsync(() => recorder.start());
    await tester.pump();

    expect(find.text('Der Mikrofonzugriff wurde verweigert. Erlauben Sie den Zugriff in den Browser- oder Geräteeinstellungen und versuchen Sie es erneut.'), findsOneWidget);
  });

  testWidgets('shows the German "recording" message while recording starts', (tester) async {
    late DatabaseService db;
    await tester.runAsync(() async {
      db = createTestDatabaseService();
      await db.initialize();
    });
    final capture = FakeAudioCapture();
    final recorder = buildRecorder(db, capture);
    final position = ValueNotifier<LatLng>(const LatLng(10, 10));

    await tester.pumpWidget(
        _wrapDe(db, QuickAddSheet(position: position, recorderController: recorder)));
    await _settle(tester);

    await tester.runAsync(() => recorder.start());
    await tester.pump();

    expect(find.text('Aufnahme läuft…'), findsOneWidget);
    expect(find.bySemanticsLabel('Aufnahme beenden'), findsOneWidget);
  });
}
