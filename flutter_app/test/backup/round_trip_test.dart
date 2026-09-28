// End-to-end round trip: back up a small "database" full of every entity
// type plus several recordings, restore it into an empty destination, and
// compare every document and every recording's bytes, byte for byte.
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/backup/backup_restorer.dart';
import 'package:relationship_manager/backup/backup_source.dart';
import 'package:relationship_manager/backup/backup_writer.dart';

import 'fakes.dart';

void main() {
  test('backup, wipe, restore reproduces every document and every recording byte for byte',
      () async {
    final rec1 = buildTestWav(5000, seed: 11);
    final rec2 = buildTestWav(8000, seed: 22);

    final source = FakeBackupDataSource(
      tables: {
        'persons': [
          makeRecord('persons', 'p1', data: {'name': 'Ada Lovelace'}),
          makeRecord('persons', 'p2',
              data: {'name': 'Deleted Person'}, isDeleted: true),
        ],
        'connections': [
          makeRecord('connections', 'c1',
              data: {'person1Id': 'p1', 'person2Id': 'p2', 'relationshipType': 'friend'}),
        ],
        'places': [
          makeRecord('places', 'pl1', data: {'name': 'Home', 'latitude': 1.5, 'longitude': 2.5}),
        ],
        'events': [
          makeRecord('events', 'e1', data: {
            'title': 'A story with two recordings',
            'files': [recordingFileJson('rec1'), recordingFileJson('rec2')],
          }),
        ],
        'objects': [
          makeRecord('objects', 'o1', data: {'name': 'Pocket watch'}),
        ],
      },
      recordingsOnDevice: {'rec1': rec1, 'rec2': rec2},
    );

    final output = OutputMemoryStream();
    final writeResult = await BackupWriter().write(source: source, output: output);
    expect(writeResult.manifest.missingAudio, isEmpty);

    // "Wipe": restore into a brand new, empty sink.
    final freshSink = FakeBackupDataSink();
    final restoreResult = await BackupRestorer()
        .apply(InputMemoryStream(output.getBytes()), freshSink);

    expect(restoreResult.entities.every((e) => e.outcome == MergeOutcome.added), isTrue);
    expect(restoreResult.recordings.every((r) => r.outcome == RecordingOutcome.restored),
        isTrue);

    for (final table in source.tables.keys) {
      for (final original in source.tables[table]!) {
        final restored = freshSink.tables[table]?[original.id];
        expect(restored, isNotNull, reason: '$table/${original.id} was not restored');
        expect(restored!.data, original.data);
        expect(restored.createdAt, original.createdAt);
        expect(restored.updatedAt, original.updatedAt);
        expect(restored.isDeleted, original.isDeleted);
      }
    }

    expect(freshSink.recordings['rec1'], rec1);
    expect(freshSink.recordings['rec2'], rec2);

    // Running the exact same restore again against the now-populated sink
    // must change nothing.
    final secondResult = await BackupRestorer()
        .apply(InputMemoryStream(output.getBytes()), freshSink);
    expect(secondResult.entities.every((e) => e.outcome == MergeOutcome.skipped), isTrue);
    expect(
        secondResult.recordings.every((r) => r.outcome == RecordingOutcome.alreadyPresent),
        isTrue);
    expect(freshSink.recordings['rec1'], rec1);
    expect(freshSink.recordings['rec2'], rec2);
  });
}
