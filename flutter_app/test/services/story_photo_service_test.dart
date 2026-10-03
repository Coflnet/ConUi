import 'package:relationship_manager/l10n/gen/app_localizations.dart';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:relationship_manager/backup/backup_restorer.dart';
import 'package:relationship_manager/backup/backup_writer.dart';
import 'package:relationship_manager/backup/database_backup_adapter.dart';
import 'package:relationship_manager/models/event.dart';
import 'package:relationship_manager/services/database_service.dart';
import 'package:relationship_manager/services/recording_file_store_native.dart';
import 'package:relationship_manager/services/story_photo_service.dart';
import 'package:relationship_manager/widgets/story_photo.dart';

import '../support/test_database.dart';

final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1cAAAAASUVORK5CYII=');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'photo bytes and event reference survive database reopen and backup restore',
      () async {
    final directory = Directory.systemTemp.createTempSync('story_photo');
    try {
      sqfliteFfiInit();
      final path = '${directory.path}/photos.db';
      var source = DatabaseService(factory: databaseFactoryFfi, path: path);
      final event = Event(title: 'Photo story', dateTime: DateTime(1952));
      final photo = await StoryPhotoService(source)
          .importPhoto(event.id, 'family.png', _png);
      event.files.add(photo);
      await source.saveEvent(event);
      expect(
          (await source.getEvent(event.id))!.files.single.sha256, photo.sha256);
      await (await source.database).close();
      source = DatabaseService(factory: databaseFactoryFfi, path: path);
      expect((await source.getEvent(event.id))!.files.single.fileName,
          'family.png');
      expect(await StoryPhotoService(source).readPhoto(photo.id), _png);
      final output = OutputMemoryStream();
      final sourceAdapter = DatabaseBackupAdapter(
          databaseService: source,
          recordingStore: NativeRecordingFileStore(baseDirectory: directory));
      await BackupWriter().write(source: sourceAdapter, output: output);
      final restored = createTestDatabaseService();
      final targetAdapter = DatabaseBackupAdapter(
          databaseService: restored,
          recordingStore: NativeRecordingFileStore(baseDirectory: directory));
      await BackupRestorer()
          .apply(InputMemoryStream(output.getBytes()), targetAdapter);
      final saved = (await restored.getEvent(event.id))!;
      expect(saved.files.single.id, photo.id);
      expect(await StoryPhotoService(restored).readPhoto(saved.files.single.id),
          _png);
      final pending = await (await restored.database).query('pending_changes');
      expect(pending.any((row) => row['entity_type'] == 'files'), isFalse);
      final corrupted = await sourceAdapter.readTable('files').single;
      corrupted.data['bytes'] = base64Encode(List<int>.filled(_png.length, 0));
      await expectLater(targetAdapter.applyEntityRestore([corrupted]),
          throwsA(isA<FormatException>()));
      expect(await StoryPhotoService(restored).readPhoto(photo.id), _png);
    } finally {
      directory.deleteSync(recursive: true);
    }
  });

  testWidgets(
      'thumbnail and full-size viewer read the saved original without login',
      (tester) async {
    final db = createTestDatabaseService();
    late AttachedFile photo;
    await tester.runAsync(() async {
      photo =
          await StoryPhotoService(db).importPhoto('event', 'family.png', _png);
    });
    await tester.runAsync(() async {
    await tester.pumpWidget(ChangeNotifierProvider<DatabaseService>.value(
        value: db,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: StoryPhoto(file: photo)))));
    });
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(
        (tester.widget<Image>(find.byType(Image)).image as MemoryImage).bytes,
        _png);
    await tester.runAsync(() async {
      tester.widget<InkWell>(find.byType(InkWell)).onTap!();
      await tester.pump();
    });
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(
        (tester.widget<Image>(find.byType(Image).last).image as MemoryImage)
            .bytes,
        _png);
    expect(tester.takeException(), isNull);
  });
}
