// Fallback used when neither dart:io nor dart:html is available. Should
// never actually be reached by this app's supported platforms (Android,
// iOS, desktop, web); it exists so the conditional import in
// backup_export.dart always has somewhere to resolve to. Mirrors
// backup_destination_stub.dart's role for the same reason.
import 'backup_export.dart';

BackupExportOffer createBackupExportOffer() =>
    throw UnsupportedError('No backup export offer is available on this platform.');
