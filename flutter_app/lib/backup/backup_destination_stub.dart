// Fallback used when neither dart:io nor dart:html is available. Should
// never actually be reached by this app's supported platforms (Android,
// iOS, desktop, web); it exists so the conditional import in
// backup_destination.dart always has somewhere to resolve to. Mirrors
// recording_file_store_stub.dart's role for the same reason.
import 'backup_destination.dart';

BackupDestinationProvider createBackupDestinationProvider() => throw UnsupportedError(
    'No backup destination is available on this platform.');
