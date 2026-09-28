import 'dart:js_interop';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:web/web.dart' as web;

import 'backup_destination.dart';

BackupDestinationProvider createBackupDestinationProvider() =>
    _WebBackupDestinationProvider();

/// Web has no API to stream an arbitrarily large file straight to disk the
/// way native code can, so the whole archive is built into memory (an
/// [OutputMemoryStream]) and [commit] hands the finished bytes to the
/// browser as a download via a Blob + a synthetic `<a download>` click -
/// the standard way to trigger a save-as without a server round trip. See
/// the final report for the practical size ceiling this implies.
class _WebBackupDestinationProvider implements BackupDestinationProvider {
  @override
  Future<BackupWriteTarget?> prepareTarget(String suggestedFileName) async {
    return _WebBackupWriteTarget(fileName: suggestedFileName, output: OutputMemoryStream());
  }
}

class _WebBackupWriteTarget implements BackupWriteTarget {
  final String fileName;
  @override
  final OutputStream output;
  Uint8List? _bytes;

  _WebBackupWriteTarget({required this.fileName, required this.output});

  @override
  Future<void> finish() async {
    output.flush();
    _bytes = (output as OutputMemoryStream).getBytes();
  }

  @override
  Future<InputStream> openForVerification() async {
    final bytes = _bytes;
    if (bytes == null) {
      throw StateError('finish() must be called before openForVerification()');
    }
    return InputMemoryStream(bytes);
  }

  @override
  Future<BackupSaveLocation> commit() async {
    final bytes = _bytes ?? (output as OutputMemoryStream).getBytes();
    final parts = <JSAny>[bytes.toJS].toJS;
    final blob = web.Blob(parts, web.BlobPropertyBag(type: 'application/zip'));
    final url = web.URL.createObjectURL(blob);
    final anchor = web.HTMLAnchorElement()
      ..href = url
      ..download = fileName;
    web.document.body?.appendChild(anchor);
    anchor.click();
    anchor.remove();
    web.URL.revokeObjectURL(url);
    return const BackupSaveLocation(description: '', isFilePath: false);
  }

  @override
  Future<void> abort() async {
    // Nothing was ever written outside this object's own memory - clearing
    // the reference is all "leave no partial file behind" requires here.
    _bytes = null;
  }
}
