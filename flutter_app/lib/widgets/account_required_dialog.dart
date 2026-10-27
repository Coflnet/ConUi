import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/auth_service.dart';

Future<bool> showAccountRequiredDialog(BuildContext context,
    {String? message, Future<bool> Function()? beforeSignIn}) async {
  final auth = context.read<AuthService>();
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ChangeNotifierProvider<AuthService>.value(
            value: auth,
            child: _AccountRequiredDialog(
                message: message, beforeSignIn: beforeSignIn)),
      ) ??
      false;
}

class _AccountRequiredDialog extends StatefulWidget {
  final String? message;
  final Future<bool> Function()? beforeSignIn;
  const _AccountRequiredDialog({this.message, this.beforeSignIn});

  @override
  State<_AccountRequiredDialog> createState() => _AccountRequiredDialogState();
}

class _AccountRequiredDialogState extends State<_AccountRequiredDialog> {
  bool _busy = false;
  bool _prepared = false;
  bool _preparationFailed = false;

  Future<void> _signIn(String identityProvider,
      {bool createAccount = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _preparationFailed = false;
    });
    if (!_prepared && widget.beforeSignIn != null) {
      if (!await widget.beforeSignIn!()) {
        if (mounted) {
          setState(() {
            _busy = false;
            _preparationFailed = true;
          });
        }
        return;
      }
      _prepared = true;
    }
    if (!mounted) return;
    final success = await context.read<AuthService>().signIn(
          locale: Localizations.localeOf(context).languageCode,
          createAccount: createAccount,
          identityProvider: identityProvider,
        );
    if (!mounted) return;
    if (success) {
      Navigator.pop(context, true);
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final auth = context.watch<AuthService>();
    final disabled = _busy || auth.signInRetrySeconds > 0;
    return AlertDialog(
      scrollable: true,
      title: Text(l10n.accountRequiredTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.message ?? l10n.accountRequiredBody),
          if (_preparationFailed)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(l10n.storySaveFailed,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          if (_busy)
            const Padding(
                padding: EdgeInsets.only(top: 16),
                child: LinearProgressIndicator()),
          if (auth.signInUnavailable || auth.signInFailed)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(auth.signInUnavailable
                  ? l10n.loginAccountUnavailable
                  : l10n.loginAccountFailed),
            ),
          const SizedBox(height: 16),
          FilledButton(
              onPressed: disabled ? null : () => _signIn('google'),
              child: Text(auth.signInRetrySeconds > 0
                  ? l10n.loginAccountRetryCountdown(auth.signInRetrySeconds)
                  : l10n.loginGoogleButton)),
          const SizedBox(height: 8),
          Text(l10n.loginGoogleHint),
          const SizedBox(height: 12),
          OutlinedButton(
              onPressed: disabled ? null : () => _signIn(''),
              child: Text(l10n.loginEmailButton)),
          TextButton(
              onPressed:
                  disabled ? null : () => _signIn('', createAccount: true),
              child: Text(l10n.loginEmailCreateButton)),
        ],
      ),
      actions: [
        TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel)),
      ],
    );
  }
}
