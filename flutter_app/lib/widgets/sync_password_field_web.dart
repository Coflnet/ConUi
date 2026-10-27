import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

Widget syncPasswordField({
  required TextEditingController controller,
  required String label,
  required bool enabled,
  required String? Function(String?) validator,
  required VoidCallback onSubmitted,
}) => _PasswordField(controller, label, enabled, validator, onSubmitted);

// Flutter's temporary editing element stops receiving autofill events when the
// browser loses focus. Keep this password input and its listeners mounted while
// the password-manager UI has focus, including during generation and retries.
class _PasswordField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final bool enabled;
  final String? Function(String?) validator;
  final VoidCallback onSubmitted;
  const _PasswordField(this.controller, this.label, this.enabled,
      this.validator, this.onSubmitted);

  @override
  State<_PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<_PasswordField> {
  web.HTMLInputElement? _input;

  @override
  void dispose() {
    final input = _input;
    _input = null;
    input?.value = '';
    input?.remove();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _PasswordField oldWidget) {
    super.didUpdateWidget(oldWidget);
    _input?.disabled = !widget.enabled;
  }

  @override
  Widget build(BuildContext context) => FormField<String>(
    initialValue: widget.controller.text,
    validator: (_) => widget.validator(widget.controller.text),
    builder: (field) => InputDecorator(
      decoration: InputDecoration(labelText: widget.label,
          errorText: field.errorText, enabled: widget.enabled),
      isEmpty: widget.controller.text.isEmpty,
      child: SizedBox(
        height: 28,
        child: HtmlElementView.fromTagName(
          tagName: 'form',
          onElementCreated: (element) {
            final form = element as web.HTMLFormElement;
            form.style.margin = '0';
            form.addEventListener('submit', ((web.Event event) {
              event.preventDefault();
              if (widget.enabled) widget.onSubmitted();
            }).toJS);
            final input = _input = web.HTMLInputElement()
              ..type = 'password'
              ..name = 'con-encryption-password'
              ..autocomplete = 'current-password'
              ..autofocus = true
              ..disabled = !widget.enabled
              ..value = widget.controller.text;
            input.setAttribute('aria-label', widget.label);
            input.style.cssText = 'width:100%;height:28px;box-sizing:border-box;'
                'border:0;outline:auto;outline-offset:2px;background:transparent;font:16px sans-serif;'
                'color:#${Theme.of(context).colorScheme.onSurface.toARGB32().toRadixString(16).substring(2)};';
            void update(web.Event _) {
              widget.controller.text = input.value;
              field.didChange(input.value);
            }
            input.addEventListener('input', update.toJS);
            input.addEventListener('change', update.toJS);
            form.append(input);
          },
        ),
      ),
    ),
  );
}
