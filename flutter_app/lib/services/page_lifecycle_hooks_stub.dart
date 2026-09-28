// Fallback used when neither dart:io nor dart:html is available. Should
// never actually be reached by this app's supported platforms; it exists
// so the conditional import in page_lifecycle_hooks.dart always has
// somewhere to resolve to. Same pattern as recording_file_store_stub.dart.
import 'page_lifecycle_hooks.dart';

PageLifecycleUnsubscribe onPageMightBeClosing(void Function() onMightBeClosing) {
  return () {};
}
