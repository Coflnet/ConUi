import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'package:relationship_manager/screens/map/location_picker_screen.dart';

void main() {
  for (final language in ['en', 'de']) {
    testWidgets('$language cancel discards the adjusted position',
        (tester) async {
      var completed = false;
      LatLng? result;
      await tester.pumpWidget(MaterialApp(
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
            builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      result = await Navigator.push<LatLng>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const LocationPickerScreen(
                                initialPosition: LatLng(50, 10)),
                          ));
                      completed = true;
                    },
                    child: const Text('Open'),
                  ),
                )),
      ));
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
      map.mapController!.move(const LatLng(51, 11), 15);
      await tester.pump();
      final cancel = find.widgetWithText(
          TextButton, language == 'de' ? 'Abbrechen' : 'Cancel');
      expect(tester.getTopLeft(cancel).dx, lessThan(100));
      await tester.tap(cancel);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(completed, isTrue);
      expect(result, isNull);
      expect(find.byType(LocationPickerScreen), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('confirm returns the adjusted position', (tester) async {
    LatLng? result;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
          builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await Navigator.push<LatLng>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const LocationPickerScreen(
                              initialPosition: LatLng(50, 10)),
                        ));
                  },
                  child: const Text('Open'),
                ),
              )),
    ));
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!
        .move(const LatLng(51, 11), 15);
    await tester.pump();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(result!.latitude, closeTo(51, 0.00001));
    expect(result!.longitude, closeTo(11, 0.00001));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
