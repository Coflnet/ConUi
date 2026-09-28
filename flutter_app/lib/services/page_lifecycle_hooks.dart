import 'page_lifecycle_hooks_stub.dart'
    if (dart.library.io) 'page_lifecycle_hooks_native.dart'
    if (dart.library.html) 'page_lifecycle_hooks_web.dart' as impl;

/// Call to stop listening for the page possibly closing.
typedef PageLifecycleUnsubscribe = void Function();

/// Calls [onMightBeClosing] as soon as the browser tab is hidden or starts
/// to unload (`visibilitychange` to hidden, or `pagehide`) - the earliest,
/// most reliable signal a web page gets that it might never run again.
///
/// A no-op everywhere except web (native/stub), where there's no such
/// thing to listen for and a crash is caught by the usual start-up
/// recovery path instead - see RecorderController's use of this for why
/// it matters specifically for an in-progress recording: it's the
/// difference between the next launch finding a properly finalized
/// recording versus one that still needs [RecordingRecoveryService] to
/// patch up.
PageLifecycleUnsubscribe onPageMightBeClosing(void Function() onMightBeClosing) =>
    impl.onPageMightBeClosing(onMightBeClosing);
