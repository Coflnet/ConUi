import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/gen/app_localizations.dart';
import '../models/models.dart';

Future<DateTime?> pickStoryDate(
    BuildContext context, DateTime initial, DatePrecision precision) async {
  if (precision == DatePrecision.year || precision == DatePrecision.month) {
    return showDialog<DateTime>(
        context: context,
        builder: (_) =>
            _PartialDateDialog(initial: initial, precision: precision));
  }
  final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1),
      lastDate: DateTime(2100, 12, 31));
  if (date == null || !context.mounted || precision == DatePrecision.day) {
    return date;
  }
  final time = await showTimePicker(
      context: context, initialTime: TimeOfDay.fromDateTime(initial));
  return time == null
      ? null
      : DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

class _PartialDateDialog extends StatefulWidget {
  final DateTime initial;
  final DatePrecision precision;
  const _PartialDateDialog({required this.initial, required this.precision});
  @override
  State<_PartialDateDialog> createState() => _PartialDateDialogState();
}

class _PartialDateDialogState extends State<_PartialDateDialog> {
  final _form = GlobalKey<FormState>();
  late final _year =
      TextEditingController(text: widget.initial.year.toString());
  late int _month = widget.initial.month;
  @override
  void dispose() {
    _year.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      scrollable: true,
      title: Text(widget.precision == DatePrecision.year
          ? l10n.quickAddWhichYear
          : l10n.quickAddWhichMonth),
      content: Form(
          key: _form,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (widget.precision == DatePrecision.month)
              DropdownButtonFormField<int>(
                  initialValue: _month,
                  items: [
                    for (var month = 1; month <= 12; month++)
                      DropdownMenuItem(
                          value: month,
                          child: Text(DateFormat.MMMM(
                                  Localizations.localeOf(context).toString())
                              .format(DateTime(2000, month)))),
                  ],
                  onChanged: (month) => _month = month!),
            TextFormField(
                controller: _year,
                keyboardType: TextInputType.number,
                autofocus: true,
                validator: (value) {
                  final year = int.tryParse(value ?? '');
                  return year == null || year < 1 || year > 2100
                      ? l10n.storyYearRange
                      : null;
                }),
          ])),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.commonCancel)),
        FilledButton(
            onPressed: () {
              if (_form.currentState!.validate()) {
                Navigator.pop(
                    context,
                    DateTime(int.parse(_year.text),
                        widget.precision == DatePrecision.month ? _month : 1));
              }
            },
            child: Text(l10n.commonOk)),
      ],
    );
  }
}
