// Fallback used when neither dart:io nor dart:html is available. Should
// never actually be reached by this app's supported platforms (Android,
// iOS, desktop, web); it exists so the conditional import in
// recording_file_store.dart always has somewhere to resolve to.
import 'recording_file_store.dart';

RecordingFileStore createRecordingFileStore() => throw UnsupportedError(
    'No RecordingFileStore implementation is available on this platform.');
