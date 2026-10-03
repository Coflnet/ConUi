import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/screens/events/events_screen.dart';
import 'package:relationship_manager/services/database_service.dart';

import 'support/fake_database_service.dart';

Future<void> openCalendar(WidgetTester tester, FakeDatabaseService db,
    {Locale locale = const Locale('en')}) async {
  await tester.pumpWidget(ChangeNotifierProvider<DatabaseService>.value(
    value: db,
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const EventsScreen(),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'year arrows retain the month and month arrows cross year boundaries',
      (tester) async {
    final db = FakeDatabaseService();
    final now = DateTime.now();
    final previous = Event(
        title: 'Previous year', dateTime: DateTime(now.year - 1, now.month, 3));
    db.events[previous.id] = previous;
    await openCalendar(tester, db);

    await tester.tap(find.byTooltip('Previous year'));
    await tester.pumpAndSettle();
    expect(find.text('Previous year'), findsOneWidget);
    expect(find.text('1 story'), findsOneWidget);
    await tester.tap(find.byTooltip('Next year'));
    await tester.pumpAndSettle();
    expect(find.text('Previous year'), findsNothing);
    expect(find.text('0 stories'), findsOneWidget);

    for (var month = now.month; month >= 1; month--) {
      await tester.tap(find.byTooltip('Previous month'));
      await tester.pumpAndSettle();
    }
    expect(find.text('December ${now.year - 1}'), findsOneWidget);
    await tester.tap(find.byTooltip('Next month'));
    await tester.pumpAndSettle();
    expect(find.text('January ${now.year}'), findsOneWidget);
  });

  testWidgets(
      'year overview counts stories and opens the latest month of a historical year',
      (tester) async {
    final db = FakeDatabaseService();
    for (final story in [
      Event(title: 'Old summer', dateTime: DateTime(1852, 6, 2)),
      Event(title: 'Old winter', dateTime: DateTime(1852, 12, 8)),
      Event(title: 'Later story', dateTime: DateTime(1990, 4, 1)),
    ]) {
      db.events[story.id] = story;
    }
    await openCalendar(tester, db);
    await tester.tap(find.text('${DateTime.now().year} · Years'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, '1852'), findsOneWidget);
    expect(find.text('2 stories'), findsOneWidget);
    expect(find.text('1 story'), findsOneWidget);

    await db.saveEvent(
        Event(title: 'Another old story', dateTime: DateTime(1852, 2)));
    await tester.pumpAndSettle();
    expect(find.text('3 stories'), findsOneWidget);

    await tester.tap(find.text('1852'));
    await tester.pumpAndSettle();
    expect(find.text('December 1852'), findsOneWidget);
    expect(find.text('Old winter'), findsOneWidget);
    expect(find.text('Old summer'), findsNothing);
    await tester.tap(find.byTooltip('Previous month'));
    await tester.pumpAndSettle();
    expect(find.text('November 1852'), findsOneWidget);
    expect(find.text('3 stories'), findsOneWidget);
  });

  testWidgets(
      'German year controls and overview fit a 390px phone with larger text',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final db = FakeDatabaseService();
    final story = Event(title: 'Erinnerung', dateTime: DateTime(1852, 6));
    db.events[story.id] = story;
    await openCalendar(tester, db, locale: const Locale('de'));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('${DateTime.now().year} · Jahre'));
    await tester.pumpAndSettle();
    expect(find.text('1 Geschichte'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('1852'));
    await tester.pumpAndSettle();
    expect(find.text('Juni 1852'), findsOneWidget);
    expect(find.text('Erinnerung'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
