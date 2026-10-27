import 'package:flutter/material.dart';

Widget syncPasswordField({
  required TextEditingController controller,
  required String label,
  required bool enabled,
  required String? Function(String?) validator,
  required VoidCallback onSubmitted,
}) => TextFormField(
  controller: controller,
  autofocus: true,
  obscureText: true,
  autofillHints: const [AutofillHints.password],
  enabled: enabled,
  autocorrect: false,
  enableSuggestions: false,
  decoration: InputDecoration(labelText: label),
  validator: validator,
  onFieldSubmitted: (_) => onSubmitted(),
);
