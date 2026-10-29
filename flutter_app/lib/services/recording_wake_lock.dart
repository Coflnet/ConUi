import 'package:wakelock_plus/wakelock_plus.dart';

/// A recording owns its screen lock until capture stops. Serialize platform
/// requests so disposal during acquisition cannot leave a late lock behind.
class RecordingWakeLock {
  static final _owners = <RecordingWakeLock>{};
  static Future<void> _pending = Future.value();
  final Future<void> Function({required bool enable}) _toggle;

  RecordingWakeLock({
    Future<void> Function({required bool enable}) toggle = WakelockPlus.toggle,
  }) : _toggle = toggle;

  Future<void> setEnabled(bool enabled) {
    final wasAwake = _owners.isNotEmpty;
    if (enabled) {
      _owners.add(this);
    } else {
      _owners.remove(this);
    }
    final keepAwake = _owners.isNotEmpty;
    if (wasAwake == keepAwake) return _pending;
    return _pending = _pending.then((_) async {
      try {
        await _toggle(enable: keepAwake);
      } catch (_) {
        // Unsupported browsers or OS power policy must not break recording.
      }
    });
  }
}
