// Native (Android/iOS/desktop): nothing to listen for here - a crash or
// kill is instead caught by RecordingRecoveryService at the next launch,
// via the WAV file left on disk (see NativeRecordingFileStore's doc
// comment on crash safety).
import 'page_lifecycle_hooks.dart';

PageLifecycleUnsubscribe onPageMightBeClosing(void Function() onMightBeClosing) {
  return () {};
}
