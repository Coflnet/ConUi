import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/page_lifecycle_hooks.dart';

class UnsavedDraftGuard extends StatefulWidget {
  final Widget child;
  final bool Function() isDirty;
  final bool Function()? isBusy;
  final Future<bool> Function() onSaveDraft;
  final Future<void> Function() onDiscard;

  const UnsavedDraftGuard(
      {super.key,
      required this.child,
      required this.isDirty,
      required this.onSaveDraft,
      required this.onDiscard,
      this.isBusy});

  @override
  State<UnsavedDraftGuard> createState() => UnsavedDraftGuardState();
}

class UnsavedDraftGuardState extends State<UnsavedDraftGuard> {
  bool _asking = false;
  bool _allowPop = false;
  late final PageLifecycleUnsubscribe _removeUnloadWarning;

  @override
  void initState() {
    super.initState();
    _removeUnloadWarning = onBeforePageUnload(
        () => !_allowPop && (widget.isDirty() || (widget.isBusy?.call() ?? false)));
  }

  @override
  void dispose() {
    _removeUnloadWarning();
    super.dispose();
  }

  Future<bool> confirm() async {
    if (_asking || (widget.isBusy?.call() ?? false)) return false;
    if (!widget.isDirty()) return true;
    _asking = true;
    try {
      final l10n = AppLocalizations.of(context);
      final choice = await showDialog<int>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text(l10n.storyDraftTitle),
          content: Text(l10n.storyDraftBody),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, 0),
                child: Text(l10n.storyDraftKeepEditing)),
            TextButton(
                onPressed: () => Navigator.pop(context, 1),
                child: Text(l10n.storyDraftDiscard)),
            FilledButton(
                onPressed: () => Navigator.pop(context, 2),
                child: Text(l10n.storyDraftSave)),
          ],
        ),
      );
      if (choice == 2) {
        final saved = await widget.onSaveDraft();
        if (saved) _allowPop = true;
        return saved;
      }
      if (choice == 1) {
        await widget.onDiscard();
        _allowPop = true;
        return true;
      }
      return false;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context).storyDraftSaveFailed)));
      }
      return false;
    } finally {
      _asking = false;
    }
  }

  Future<void> _close() async {
    if (await confirm() && mounted) {
      setState(() => _allowPop = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: _allowPop,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _close();
        },
        child: widget.child,
      );
}
