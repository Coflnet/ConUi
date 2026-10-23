import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../models/models.dart';
import '../../services/database_service.dart';
import '../../services/local_draft_store.dart';
import '../../services/interaction_feedback.dart';
import '../../widgets/unsaved_draft_guard.dart';

class AddPersonScreen extends StatefulWidget {
  final Person? existingPerson;

  const AddPersonScreen({super.key, this.existingPerson});

  @override
  State<AddPersonScreen> createState() => _AddPersonScreenState();
}

class _AddPersonScreenState extends State<AddPersonScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _aliasesController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _companyController = TextEditingController();
  final _jobTitleController = TextEditingController();
  final _addressController = TextEditingController();
  final _notesController = TextEditingController();
  DateTime? _birthday;
  DateTime? _deathDate;
  bool _isSaving = false;
  String _draftId = Person(name: '').id;
  late String _originalDraft;
  String get _draftKey => 'person.${widget.existingPerson?.id ?? 'new'}';
  List<TextEditingController> get _fields => [_nameController, _aliasesController,
    _emailController, _phoneController, _companyController, _jobTitleController,
    _addressController, _notesController];
  Map<String, dynamic> _draft() => {'id': _draftId,
    'fields': _fields.map((field) => field.text).toList(),
    'birthday': _birthday?.toIso8601String(), 'deathDate': _deathDate?.toIso8601String()};

  Future<void> _restoreDraft() async {
    try {
      final draft = await LocalDraftStore.read(_draftKey);
      if (draft == null || !mounted || jsonEncode(_draft()) != _originalDraft) return;
      setState(() {
        _draftId = draft['id'] as String;
        final fields = (draft['fields'] as List).cast<String>();
        for (var i = 0; i < _fields.length; i++) { _fields[i].text = fields[i]; }
        _birthday = DateTime.tryParse(draft['birthday'] as String? ?? '');
        _deathDate = DateTime.tryParse(draft['deathDate'] as String? ?? '');
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).storyDraftRestored)));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).storyDraftSaveFailed)));
    }
  }


  bool get _isEditing => widget.existingPerson != null;

  @override
  void initState() {
    super.initState();
    if (widget.existingPerson != null) {
      final p = widget.existingPerson!;
      _draftId = p.id;
      _nameController.text = p.name;
      _aliasesController.text = p.aliases.join(', ');
      _emailController.text = p.email ?? '';
      _phoneController.text = p.phoneNumber ?? '';
      _companyController.text = p.company ?? '';
      _jobTitleController.text = p.jobTitle ?? '';
      _addressController.text = p.address ?? '';
      _notesController.text = p.notes ?? '';
      _birthday = p.birthday;
      _deathDate = p.deathDate;
    }
    _originalDraft = jsonEncode(_draft());
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreDraft());
  }

  @override
  void dispose() {
    _nameController.dispose();
    _aliasesController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _companyController.dispose();
    _jobTitleController.dispose();
    _addressController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _selectBirthday() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _birthday ?? DateTime(1990),
      firstDate: DateTime(1),
      lastDate: _birthday != null && _birthday!.isAfter(DateTime.now()) ? _birthday! : DateTime.now(),
    );
    if (date != null) {
      setState(() {
        _birthday = date;
      });
    }
  }

  Future<void> _selectDeathDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _deathDate ?? _birthday ?? DateTime.now(),
      firstDate: DateTime(1),
      lastDate: _deathDate != null && _deathDate!.isAfter(DateTime.now()) ? _deathDate! : DateTime.now(),
    );
    if (date != null) {
      setState(() {
        _deathDate = date;
      });
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_birthday != null && _deathDate != null && _deathDate!.isBefore(_birthday!)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).peopleDatesInvalid)));
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final db = context.read<DatabaseService>();

      final person = _isEditing
          ? widget.existingPerson!.copyWith(
              name: _nameController.text.trim(),
              aliases: _aliasesController.text.trim().isEmpty
                  ? []
                  : _aliasesController.text
                      .split(',')
                      .map((e) => e.trim())
                      .toList(),
              clearEmail: _emailController.text.trim().isEmpty,
              email: _emailController.text.trim().isEmpty
                  ? null
                  : _emailController.text.trim(),
              clearPhoneNumber: _phoneController.text.trim().isEmpty,
              phoneNumber: _phoneController.text.trim().isEmpty
                  ? null
                  : _phoneController.text.trim(),
              clearCompany: _companyController.text.trim().isEmpty,
              company: _companyController.text.trim().isEmpty
                  ? null
                  : _companyController.text.trim(),
              clearJobTitle: _jobTitleController.text.trim().isEmpty,
              jobTitle: _jobTitleController.text.trim().isEmpty
                  ? null
                  : _jobTitleController.text.trim(),
              clearAddress: _addressController.text.trim().isEmpty,
              address: _addressController.text.trim().isEmpty
                  ? null
                  : _addressController.text.trim(),
              clearNotes: _notesController.text.trim().isEmpty,
              notes: _notesController.text.trim().isEmpty
                  ? null
                  : _notesController.text.trim(),
              birthday: _birthday,
              clearBirthday: _birthday == null,
              deathDate: _deathDate,
              clearDeathDate: _deathDate == null,
            )
          : Person(
              id: _draftId,
              name: _nameController.text.trim(),
              aliases: _aliasesController.text.trim().isEmpty
                  ? []
                  : _aliasesController.text
                      .split(',')
                      .map((e) => e.trim())
                      .toList(),
              email: _emailController.text.trim().isEmpty
                  ? null
                  : _emailController.text.trim(),
              phoneNumber: _phoneController.text.trim().isEmpty
                  ? null
                  : _phoneController.text.trim(),
              company: _companyController.text.trim().isEmpty
                  ? null
                  : _companyController.text.trim(),
              jobTitle: _jobTitleController.text.trim().isEmpty
                  ? null
                  : _jobTitleController.text.trim(),
              address: _addressController.text.trim().isEmpty
                  ? null
                  : _addressController.text.trim(),
              notes: _notesController.text.trim().isEmpty
                  ? null
                  : _notesController.text.trim(),
              birthday: _birthday,
              deathDate: _deathDate,
            );

      await db.savePerson(person);
      await LocalDraftStore.remove(_draftKey);
      if (mounted) context.read<InteractionFeedback?>()?.play(FeedbackCue.success);

      if (mounted) {
        final l10n = AppLocalizations.of(context);
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(l10n.addPersonSavedSnackbar(
                  person.name,
                  _isEditing
                      ? l10n.addPersonSavedActionUpdated
                      : l10n.addPersonSavedActionAdded))),
        );
      }
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).peopleSaveFailed)));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toString();
    return UnsavedDraftGuard(
      isDirty: () => jsonEncode(_draft()) != _originalDraft,
      isBusy: () => _isSaving,
      onSaveDraft: () async { await LocalDraftStore.write(_draftKey, _draft()); return true; },
      onDiscard: () => LocalDraftStore.remove(_draftKey),
      child: Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? l10n.addPersonTitleEdit : l10n.addPersonTitleNew),
        actions: [
          TextButton(
            onPressed: _isSaving ? null : _save,
            child: _isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.commonSave),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: l10n.addPersonNameLabel,
                prefixIcon: const Icon(Icons.person),
              ),
              textCapitalization: TextCapitalization.words,
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return l10n.addPersonNameRequired;
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _aliasesController,
              decoration: InputDecoration(
                labelText: l10n.addPersonAliasesLabel,
                prefixIcon: const Icon(Icons.label),
                helperText: l10n.addPersonAliasesHelper,
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _emailController,
              decoration: InputDecoration(
                labelText: l10n.addPersonEmailLabel,
                prefixIcon: const Icon(Icons.email),
              ),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _phoneController,
              decoration: InputDecoration(
                labelText: l10n.addPersonPhoneLabel,
                prefixIcon: const Icon(Icons.phone),
              ),
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.cake),
              title: Text(_birthday == null
                  ? l10n.addPersonBirthdayLabel
                  : DateFormat.yMd(locale).format(_birthday!)),
              subtitle: Text(l10n.addPersonTapToSelect),
              onTap: _selectBirthday,
              trailing: _birthday != null
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        setState(() {
                          _birthday = null;
                        });
                      },
                    )
                  : null,
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.event_busy),
              title: Text(_deathDate == null
                  ? l10n.addPersonDeathDateLabel
                  : DateFormat.yMd(locale).format(_deathDate!)),
              subtitle: Text(l10n.addPersonDeathDateOptional),
              onTap: _selectDeathDate,
              trailing: _deathDate != null
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        setState(() {
                          _deathDate = null;
                        });
                      },
                    )
                  : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _companyController,
              decoration: InputDecoration(
                labelText: l10n.addPersonCompanyLabel,
                prefixIcon: const Icon(Icons.business),
              ),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _jobTitleController,
              decoration: InputDecoration(
                labelText: l10n.addPersonJobTitleLabel,
                prefixIcon: const Icon(Icons.work),
              ),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _addressController,
              decoration: InputDecoration(
                labelText: l10n.addPersonAddressLabel,
                prefixIcon: const Icon(Icons.location_on),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _notesController,
              decoration: InputDecoration(
                labelText: l10n.addPersonNotesLabel,
                prefixIcon: const Icon(Icons.note),
              ),
              maxLines: 4,
            ),
          ],
        ),
      ),
    ));
  }
}
