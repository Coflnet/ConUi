import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mime/mime.dart';

import '../models/event.dart';
import 'database_service.dart';

/// Local photos live in the app database, including IndexedDB on web.
/// Event metadata contains only a reference; cloud attachment transfer is separate.
class StoryPhotoService {
  final DatabaseService databaseService;

  StoryPhotoService(this.databaseService);

  Future<List<AttachedFile>> pickPhotos(String eventId) async {
    final selection = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: true,
    );
    final photos = <AttachedFile>[];
    for (final file in selection?.files ?? <PlatformFile>[]) {
      final bytes = file.bytes;
      if (bytes == null) throw StateError('Photo bytes unavailable');
      photos.add(await importPhoto(eventId, file.name, bytes));
    }
    return photos;
  }

  Future<AttachedFile> importPhoto(
      String eventId, String name, Uint8List bytes) async {
    final mimeType = lookupMimeType(name, headerBytes: bytes);
    if (mimeType == null || !mimeType.startsWith('image/')) {
      throw const FormatException('Unsupported image');
    }
    final photo = AttachedFile(
      fileName: name,
      filePath: '',
      mimeType: mimeType,
      size: bytes.length,
      sha256: sha256.convert(bytes).toString(),
    );
    photo.filePath = 'local-photo:${photo.id}';
    final db = await databaseService.database;
    await db.insert('files', {
      'id': photo.id,
      'entity_type': 'event',
      'entity_id': eventId,
      'file_name': photo.fileName,
      'file_path': photo.filePath,
      'mime_type': photo.mimeType,
      'size': photo.size,
      'created_at': photo.addedAt.toIso8601String(),
      'bytes': bytes,
    });
    return photo;
  }

  Future<Uint8List> readPhoto(String id) async {
    final db = await databaseService.database;
    final rows = await db.query('files',
        columns: ['bytes'], where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty || rows.first['bytes'] == null) {
      throw StateError('Photo unavailable on this device');
    }
    return rows.first['bytes'] as Uint8List;
  }
}
