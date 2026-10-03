// Regression tests for two of the l10n work package's specific
// requirements: ICU plural forms in German (not just English) and date
// formatting through intl with the active locale, at each DatePrecision.
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:relationship_manager/l10n/gen/app_localizations_de.dart';
import 'package:relationship_manager/l10n/gen/app_localizations_en.dart';
import 'package:relationship_manager/models/event.dart';
import 'package:relationship_manager/screens/map/nearby_place.dart';
import 'package:latlong2/latlong.dart';

void main() {
  final en = AppLocalizationsEn();
  final de = AppLocalizationsDe();

  // DateFormat with an explicit locale string needs that locale's symbol
  // data loaded first - normally done for free by flutter_localizations
  // when a MaterialApp starts; this is a plain Dart test with no widget
  // tree, so it must be loaded explicitly.
  setUpAll(() async {
    await initializeDateFormatting('en');
    await initializeDateFormatting('de');
  });

  test('unnamed places use the active language', () {
    const point = LatLng(50, 10);
    expect(defaultPlaceName(point, de), 'Unbenannter Ort (50.000, 10.000)');
    expect(defaultPlaceName(point, en), 'Unnamed place (50.000, 10.000)');
  });

  group('ICU plurals render correctly in German, not just English', () {
    test('recoveredBannerCount: singular vs. plural wording actually differs', () {
      expect(de.recoveredBannerCount(1), '1 Aufnahme ist keiner Geschichte zugeordnet');
      expect(de.recoveredBannerCount(3), '3 Aufnahmen sind keiner Geschichte zugeordnet');
      // The singular/plural verb ("ist"/"sind") and noun ending ("Aufnahme"/
      // "Aufnahmen") must both switch - a naive "count + one fixed string"
      // template (fine in English) would get German wrong here.
      expect(de.recoveredBannerCount(1), isNot(contains('sind')));
      expect(de.recoveredBannerCount(3), isNot(contains(' ist ')));
    });

    test('backupPreviewPersons: German plural noun differs from the singular, unlike English',
        () {
      expect(en.backupPreviewPersons(1), '1 person');
      expect(en.backupPreviewPersons(2), '2 people');
      expect(de.backupPreviewPersons(1), '1 Person');
      expect(de.backupPreviewPersons(2), '2 Personen');
    });

    test('objectsInvolvedInCount: zero/one/many all read as natural German sentences', () {
      expect(de.objectsInvolvedInCount(1), 'Kommt in 1 Geschichte vor');
      expect(de.objectsInvolvedInCount(5), 'Kommt in 5 Geschichten vor');
    });
  });

  group('dates are formatted through intl with the active locale, per DatePrecision', () {
    final date = DateTime(1952, 6, 12, 15, 45);

    test('year precision: locale-independent digits', () {
      expect(formatDateWithPrecision(date, DatePrecision.year, 'en'), '1952');
      expect(formatDateWithPrecision(date, DatePrecision.year, 'de'), '1952');
    });

    test('month-and-year precision: the month name is translated', () {
      expect(formatDateWithPrecision(date, DatePrecision.month, 'en'), 'June 1952');
      expect(formatDateWithPrecision(date, DatePrecision.month, 'de'), 'Juni 1952');
    });

    test('full date precision: German uses day.month.year ordering, not month/day/year', () {
      final enDate = formatDateWithPrecision(date, DatePrecision.day, 'en');
      final deDate = formatDateWithPrecision(date, DatePrecision.day, 'de');
      expect(enDate, 'Jun 12, 1952');
      expect(deDate, '12. Juni 1952');
    });

    test('full date+time precision: German time-of-day formatting', () {
      final enDateTime = formatDateWithPrecision(date, DatePrecision.time, 'en');
      final deDateTime = formatDateWithPrecision(date, DatePrecision.time, 'de');
      expect(enDateTime, contains('1952'));
      expect(enDateTime, contains('3:45'));
      expect(deDateTime, contains('1952'));
      expect(deDateTime, contains('15:45'));
    });

    test('omitting the locale falls back to intl\'s own default rather than throwing', () {
      expect(() => formatDateWithPrecision(date, DatePrecision.year), returnsNormally);
    });
  });
}
