import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/interaction_feedback.dart';
import '../services/sync_service.dart';
import 'account_required_dialog.dart';
import 'sync_password_field.dart'
    if (dart.library.js_interop) 'sync_password_field_web.dart';

Future<bool> syncWithPrompts(BuildContext context) async {
  final sync = context.read<SyncService>();
  if (sync.isSyncing) return false;
  if (sync.needsSignIn && !await showAccountRequiredDialog(context)) {
    return false;
  }
  if (!context.mounted) return false;
  bool success;
  if (!sync.isUnlocked) {
    success = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _UnlockSyncDialog(sync: sync),
        ) ??
        false;
  } else {
    try {
      await sync.forceFullSync();
      success = sync.lastError == null && !sync.needsSignIn && sync.isUnlocked;
    } catch (_) {
      success = false;
    }
  }
  if (context.mounted && success) {
    context.read<InteractionFeedback?>()?.play(FeedbackCue.success);
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).homeSyncComplete)));
  } else if (context.mounted && sync.isUnlocked) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(sync.lastError?.contains('storage_unavailable') == true
            ? AppLocalizations.of(context).syncStorageUnavailable
            : AppLocalizations.of(context).settingsSyncRecovery),
        action: SnackBarAction(
            label: AppLocalizations.of(context).commonRetry,
            onPressed: () => syncWithPrompts(context))));
  }
  return success;
}

class _UnlockSyncDialog extends StatefulWidget {
  final SyncService sync;
  const _UnlockSyncDialog({required this.sync});

  @override
  State<_UnlockSyncDialog> createState() => _UnlockSyncDialogState();
}

class _UnlockSyncDialogState extends State<_UnlockSyncDialog> {
  final _password = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _busy = false;
  bool _failed = false;

  Future<void> _unlock() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await widget.sync.initializeEncryption(_password.text);
      // Download/decrypt before any upload, so a wrong password cannot replace
      // existing encrypted data. forceFullSync aborts uploads on read failure.
      await widget.sync.forceFullSync();
      if (widget.sync.lastError != null || !widget.sync.isUnlocked) {
        throw StateError('Sync did not complete');
      }
      TextInput.finishAutofillContext();
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      widget.sync.lockEncryption();
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        scrollable: true,
        title: Text(l10n.syncUnlockTitle),
        content: AutofillGroup(
          onDisposeAction: AutofillContextAction.cancel,
          child: Form(
            key: _form,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(l10n.syncUnlockBody),
              const SizedBox(height: 16),
              syncPasswordField(
                controller: _password,
                label: l10n.loginPasswordLabel,
                enabled: !_busy,
                validator: (v) =>
                    v == null || v.isEmpty ? l10n.syncPasswordRequired : null,
                onSubmitted: _unlock,
              ),
              if (_failed)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(widget.sync.lastError?.contains('storage_unavailable') == true
                      ? l10n.syncStorageUnavailable
                      : l10n.syncUnlockFailed,
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              if (_busy)
                Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: LinearProgressIndicator(
                        semanticsLabel: l10n.syncInProgress)),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context, false),
              child: Text(l10n.commonCancel)),
          FilledButton(
              onPressed: _busy ? null : _unlock,
              child: Text(_busy ? l10n.syncInProgress : l10n.syncUnlockAction)),
        ],
      ),
    );
  }
}
