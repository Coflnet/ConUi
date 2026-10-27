import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/services/auth_service.dart';
import 'package:relationship_manager/services/sync_service.dart';
import 'package:relationship_manager/widgets/sync_progress_indicator.dart';

import '../support/test_database.dart';

class ProgressSync extends SyncService {
  ProgressSync() : super(createTestDatabaseService(), AuthService());

  @override
  bool isSyncing = true;

  @override
  SyncPhase phase = SyncPhase.preparing;
  @override
  int completedItems = 0;
  @override
  int totalItems = 0;
  @override
  Duration? estimatedRemaining;
  @override
  int completedRecordingChunks = 0;
  @override
  int totalRecordingChunks = 0;

  void update() => notifyListeners();
}

Widget progressApp(ProgressSync sync, String locale) => MaterialApp(
      locale: Locale(locale),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SyncProgressIndicator(sync: sync)),
    );

void main() {
  for (final locale in ['en', 'de']) {
    testWidgets('observable step counts, numeric progress and ETA ($locale)',
        (tester) async {
      final sync = ProgressSync();
      await tester.pumpWidget(progressApp(sync, locale));
      await tester.pump();
      expect(
          tester
              .widget<LinearProgressIndicator>(
                  find.byType(LinearProgressIndicator))
              .value,
          isNull);
      expect(find.textContaining('0%'), findsNothing);
      sync.phase = SyncPhase.downloading;
      sync.update();
      await tester.pump();
      expect(
          tester
              .widget<LinearProgressIndicator>(
                  find.byType(LinearProgressIndicator))
              .value,
          isNull);
      expect(find.textContaining('0 of 0'), findsNothing);
      sync
        ..phase = SyncPhase.downloading
        ..completedItems = 3
        ..totalItems = 20;
      sync.update();
      await tester.pump();
      expect(
          find.text(locale == 'en'
              ? 'Downloading 3 of 20 items (15%)'
              : '3 von 20 Einträgen heruntergeladen (15 %)'),
          findsOneWidget);
      var indicator = tester.widget<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator));
      expect(indicator.value, 0.15);
      expect(indicator.semanticsValue, '15%');
      expect(
          find.text(locale == 'en'
              ? 'Estimating time remaining in this step…'
              : 'Verbleibende Zeit für diesen Schritt wird geschätzt…'),
          findsOneWidget);
      sync.estimatedRemaining = const Duration(milliseconds: 400);
      sync.update();
      await tester.pump();
      expect(
          find.text(locale == 'en'
              ? 'About 1 second remaining in this step'
              : 'Noch ca. 1 Sekunde in diesem Schritt'),
          findsOneWidget);
      sync
        ..phase = SyncPhase.uploading
        ..completedItems = 4
        ..estimatedRemaining = const Duration(seconds: 61);
      sync.update();
      await tester.pump();
      expect(
          find.text(locale == 'en'
              ? 'Uploading 4 of 20 items (20%)'
              : '4 von 20 Einträgen hochgeladen (20 %)'),
          findsOneWidget);
      expect(
          find.text(locale == 'en'
              ? 'About 2 minutes remaining in this step'
              : 'Noch ca. 2 Minuten in diesem Schritt'),
          findsOneWidget);
      sync
        ..completedRecordingChunks = 2
        ..totalRecordingChunks = 4
        ..estimatedRemaining = const Duration(minutes: 61);
      sync.update();
      await tester.pump();
      expect(
          find.text(locale == 'en'
              ? 'Recording transfer: 50%'
              : 'Aufnahmeübertragung: 50 %'),
          findsOneWidget);
      expect(
          find.text(locale == 'en'
              ? 'About 2 hours remaining for this recording'
              : 'Noch ca. 2 Stunden für diese Aufnahme'),
          findsOneWidget);
      sync
        ..completedRecordingChunks = 4
        ..estimatedRemaining = null;
      sync.update();
      await tester.pump();
      expect(
          find.text(locale == 'en'
              ? 'Verifying and saving recording…'
              : 'Aufnahme wird geprüft und gespeichert…'),
          findsOneWidget);
      sync
        ..phase = SyncPhase.finishing
        ..totalRecordingChunks = 0
        ..estimatedRemaining = null;
      sync.update();
      await tester.pump();
      indicator = tester.widget<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator));
      expect(indicator.value, isNull);
      expect(find.textContaining(locale == 'en' ? 'remaining' : 'Noch'),
          findsNothing);
      expect(
          find.text(locale == 'en'
              ? 'Finishing encrypted sync…'
              : 'Verschlüsselte Synchronisierung wird abgeschlossen…'),
          findsOneWidget);
      sync
        ..isSyncing = false
        ..phase = SyncPhase.uploading;
      sync.update();
      await tester.pump();
      expect(
          find.text(locale == 'en'
              ? 'Preparing encrypted sync…'
              : 'Verschlüsselte Synchronisierung wird vorbereitet…'),
          findsOneWidget);
      expect(find.textContaining('4 of 20'), findsNothing);
    });
  }
}
