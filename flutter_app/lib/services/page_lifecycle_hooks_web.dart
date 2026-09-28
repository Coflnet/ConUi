import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'page_lifecycle_hooks.dart';

/// `visibilitychange` fires both when the tab is hidden AND when it comes
/// back - only the former is "might be closing". `pagehide` always means
/// the page is being torn down (a real close, reload or navigation), so
/// it always counts.
PageLifecycleUnsubscribe onPageMightBeClosing(void Function() onMightBeClosing) {
  void onVisibilityChange(web.Event event) {
    if (web.document.visibilityState == 'hidden') onMightBeClosing();
  }

  void onPageHide(web.Event event) => onMightBeClosing();

  final visibilityListener = onVisibilityChange.toJS;
  final pageHideListener = onPageHide.toJS;
  web.document.addEventListener('visibilitychange', visibilityListener);
  web.window.addEventListener('pagehide', pageHideListener);

  return () {
    web.document.removeEventListener('visibilitychange', visibilityListener);
    web.window.removeEventListener('pagehide', pageHideListener);
  };
}
