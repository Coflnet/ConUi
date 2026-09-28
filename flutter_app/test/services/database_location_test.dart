// Regression tests for lib/services/database_location.dart.
//
// The app used to open its database at a path relative to the process's
// current working directory (`relationship_manager.db`), which isn't
// writable on Android at all - that's what crashed the app at start with
// `SqfliteFfiException ... unable to open database file (code 14)` - and
// on desktop depended on wherever the app happened to be launched from.
//
// These tests exercise the fix directly against the native implementation
// (safe: `flutter test` always runs on a native VM, never web), without
// going through DatabaseService, whose tests always inject an explicit
// factory/path and so never reach this code at all.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:relationship_manager/services/database_location.dart';
import 'package:relationship_manager/services/database_location_native.dart'
    as native;

void main() {
  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('db_location_test_');
  });

  tearDown(() {
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  group('resolveDatabaseLocation', () {
    test('resolves to an absolute path under the support directory',
        () async {
      final supportDir = Directory(p.join(tempRoot.path, 'support'));

      final location = await native.resolveDatabaseLocation(
        'relationship_manager.db',
        supportDirectoryOverride: supportDir.path,
      );

      expect(location.path,
          p.join(supportDir.path, 'relationship_manager.db'));
      expect(p.isAbsolute(location.path), isTrue);
      // Neither Android nor iOS: this test runs on the desktop/CI host.
      expect(location.useNativePlugin, isFalse);
    });

    test('creates the support directory if it does not exist yet',
        () async {
      final supportDir = Directory(p.join(tempRoot.path, 'does_not_exist'));
      expect(supportDir.existsSync(), isFalse);

      await native.resolveDatabaseLocation(
        'relationship_manager.db',
        supportDirectoryOverride: supportDir.path,
      );

      expect(supportDir.existsSync(), isTrue);
    });

    test(
        'migrates an old database file at the previous CWD-relative path '
        'to the new location, preserving its contents', () async {
      const fileName = 'relationship_manager.db';
      final supportDir = Directory(p.join(tempRoot.path, 'support'));
      final oldCwd = Directory(p.join(tempRoot.path, 'old_cwd'))
        ..createSync(recursive: true);

      final oldFile = File(p.join(oldCwd.path, fileName));
      oldFile.writeAsBytesSync([1, 2, 3, 4]);

      final previousCwd = Directory.current;
      Directory.current = oldCwd;
      try {
        final location = await native.resolveDatabaseLocation(
          fileName,
          supportDirectoryOverride: supportDir.path,
        );

        expect(File(location.path).existsSync(), isTrue,
            reason: 'the database must exist at the new location');
        expect(File(location.path).readAsBytesSync(), [1, 2, 3, 4],
            reason: 'the old database contents must be preserved');
        expect(oldFile.existsSync(), isFalse,
            reason: 'the old file must be moved, not copied and left behind');
      } finally {
        Directory.current = previousCwd;
      }
    });

    test(
        'does not touch an old CWD-relative file when a database already '
        'exists at the new location (never overwrite real data)', () async {
      const fileName = 'relationship_manager.db';
      final supportDir = Directory(p.join(tempRoot.path, 'support'))
        ..createSync(recursive: true);
      final oldCwd = Directory(p.join(tempRoot.path, 'old_cwd'))
        ..createSync(recursive: true);

      File(p.join(supportDir.path, fileName)).writeAsBytesSync([9, 9, 9]);
      final oldFile = File(p.join(oldCwd.path, fileName));
      oldFile.writeAsBytesSync([1, 2, 3, 4]);

      final previousCwd = Directory.current;
      Directory.current = oldCwd;
      try {
        await native.resolveDatabaseLocation(
          fileName,
          supportDirectoryOverride: supportDir.path,
        );

        expect(oldFile.existsSync(), isTrue,
            reason: 'the untouched old file must be left in place');
        expect(
            File(p.join(supportDir.path, fileName)).readAsBytesSync(),
            [9, 9, 9],
            reason: 'the existing database at the new location must win');
      } finally {
        Directory.current = previousCwd;
      }
    });

    test('leaves DatabaseLocation.path untouched when no old file exists',
        () async {
      final supportDir = Directory(p.join(tempRoot.path, 'support'));

      final location = await native.resolveDatabaseLocation(
        'fresh_install.db',
        supportDirectoryOverride: supportDir.path,
      );

      expect(File(location.path).existsSync(), isFalse);
    });
  });

  test('DatabaseLocation exposes the given path and plugin flag', () {
    const location = DatabaseLocation('/tmp/foo.db', true);
    expect(location.path, '/tmp/foo.db');
    expect(location.useNativePlugin, isTrue);
  });
}
