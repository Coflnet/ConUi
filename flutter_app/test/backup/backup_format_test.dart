import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/backup/backup_format.dart';

void main() {
  group('isSafeRecordingId', () {
    test('accepts a uuid-v4-shaped id', () {
      expect(isSafeRecordingId('5b6f1c2a-1234-4abc-8def-0123456789ab'), isTrue);
    });

    test('accepts a plain alphanumeric id', () {
      expect(isSafeRecordingId('rec1'), isTrue);
    });

    test('rejects an empty id', () {
      expect(isSafeRecordingId(''), isFalse);
    });

    test('rejects ids containing a path separator', () {
      expect(isSafeRecordingId('a/b'), isFalse);
      expect(isSafeRecordingId(r'a\b'), isFalse);
    });

    test('rejects path traversal shapes', () {
      expect(isSafeRecordingId('..'), isFalse);
      expect(isSafeRecordingId('../etc/passwd'), isFalse);
      expect(isSafeRecordingId('../../x'), isFalse);
    });

    test('rejects absolute paths', () {
      expect(isSafeRecordingId('/etc/passwd'), isFalse);
      expect(isSafeRecordingId(r'C:\Windows\System32'), isFalse);
    });

    test('rejects an id over the length cap', () {
      expect(isSafeRecordingId('a' * 129), isFalse);
      expect(isSafeRecordingId('a' * 128), isTrue);
    });
  });

  group('BackupEntryNames', () {
    test('builds the expected recording path', () {
      expect(BackupEntryNames.recordingEntry('rec1'), 'recordings/rec1.wav');
    });
  });
}
