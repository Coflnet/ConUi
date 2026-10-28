import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../models/models.dart';
import '../../services/app_settings_service.dart';
import '../../services/auth_service.dart';
import '../../services/database_service.dart';
import '../../services/dia_region_service.dart';
import '../../widgets/account_required_dialog.dart';
import '../../widgets/transcript_people_picker.dart';
import '../../services/story_photo_service.dart';
import '../../services/local_draft_store.dart';
import '../../services/interaction_feedback.dart';
import '../../widgets/unsaved_draft_guard.dart';
import '../../widgets/story_date_picker.dart';
import '../../widgets/story_photo.dart';
import '../../widgets/dia_correction_dialog.dart';
import '../../services/record_package_audio_capture.dart';
import '../../services/recorder_controller.dart';
import '../../services/recording_file_store.dart';
import '../../services/transcription_client.dart';
import '../map/location_picker_screen.dart';
import '../map/nearby_place.dart';
import '../quick_add/quick_add_sheet.dart' show messageForMicFailure, messageForTranscriptionReason;
import 'events_screen.dart' show eventTypeLabel;

class AddEventScreen extends StatefulWidget {
  final Event? existingEvent; // If provided, we're editing an existing event

  /// Overridable for tests/previews, so a fake can be driven without a real
  /// microphone or backend. Production code leaves this null and gets a
  /// real RecorderController built from the app's services.
  final RecorderController? recorderController;
  final String? initialTitle;
  final List<String> initialParticipantIds;

  const AddEventScreen({super.key, this.existingEvent, this.recorderController,
    this.initialTitle, this.initialParticipantIds = const []});

  @override
  State<AddEventScreen> createState() => _AddEventScreenState();
}

class _AddEventScreenState extends State<AddEventScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  EventType _type = EventType.other;
  DateTime _dateTime = DateTime.now();
  DateTime? _endDateTime;
  List<String> _participantIds = [];
  late final TranscriptPeopleController _peoplePicker;
  String? _placeId;
  bool _isSaving = false;
  bool _isPickingPhotos = false;
  late Event _draftEvent;
  final _draftGuard = GlobalKey<UnsavedDraftGuardState>();
  late String _initialContent;
  bool _draftLoading = true;
  bool _draftRestored = false;
  bool _finalizingDraft = false;
  bool _titleEdited = false;
  bool _isTranscribingNow = false;
  bool _hasFailedTranscription = false;
  DatePrecision _datePrecision = DatePrecision.time;
  String get _draftKey => 'story:${widget.existingEvent?.id ?? "new"}';
  final List<AttachedFile> _photos = [];

  late final RecorderController _recorder;
  bool _ownsRecorder = false;
  AttachedFile? _pendingRecording;
  String _liveTextAlreadyShown = '';

  @override
  void initState() {
    super.initState();
    _draftEvent = widget.existingEvent ?? Event(title: '', dateTime: _dateTime);
    if (widget.existingEvent != null) {
      final e = widget.existingEvent!;
      _titleController.text = e.title;
      _descriptionController.text = e.description ?? '';
      _type = e.type;
      _dateTime = e.dateTime;
      _datePrecision = e.datePrecision;
      _endDateTime = e.endDateTime;
      _participantIds = List.from(e.participantIds);
      _placeId = e.placeId;
    }

    if (widget.existingEvent == null) {
      _titleController.text = widget.initialTitle ?? '';
      _participantIds = List.of(widget.initialParticipantIds);
    }

    if (widget.recorderController != null) {
      _recorder = widget.recorderController!;
    } else {
      _recorder = _buildDefaultRecorderController(context);
      _ownsRecorder = true;
    }
    _recorder.addListener(_onRecorderChanged);
    _peoplePicker = TranscriptPeopleController(_descriptionController, context.read<DatabaseService>(), preferredIds: _participantIds.toSet());
    _peoplePicker.addListener(_onPeopleChanged);
    _titleEdited = _titleController.text.isNotEmpty;
    _initialContent = jsonEncode(_currentEvent().toJson());
    _descriptionController.addListener(_updateSuggestedTitle);
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreDraft());
  }

  Event _currentEvent({String? title, List<String>? participants}) => Event.fromJson({
    ..._draftEvent.toJson(),
    'title': title ?? _titleController.text,
    'description': _descriptionController.text.trim().isEmpty ? null : _descriptionController.text.trim(),
    'type': _type.name,
    'dateTime': _dateTime.toIso8601String(),
    'datePrecision': _datePrecision.name,
    'endDateTime': _endDateTime?.toIso8601String(),
    'participantIds': participants ?? _participantIds,
    'placeId': _placeId,
    'files': [..._draftEvent.files, if (_pendingRecording != null) _pendingRecording!, ..._photos]
        .map((file) => file.toJson()).toList(),
  });

  bool get _hasUnsavedContent => _draftRestored ||
      _recorder.state == RecorderState.recording ||
      jsonEncode(_currentEvent().toJson()) != _initialContent || _peoplePicker.hasDraftDecisions;

  Future<void> _restoreDraft() async {
    try {
      final draft = await LocalDraftStore.read(_draftKey);
      if (!mounted || draft == null) return;
      final event = Event.fromJson(Map<String, dynamic>.from(draft['event']));
      _draftEvent = widget.existingEvent ?? event.copyWith(files: []);
      _titleEdited = draft['titleEdited'] == true;
      _titleController.text = event.title;
      _descriptionController.text = event.description ?? '';
      _type = event.type;
      _dateTime = event.dateTime;
      _datePrecision = event.datePrecision;
      _endDateTime = event.endDateTime;
      _participantIds = event.participantIds;
      _placeId = event.placeId;
      _photos.addAll((draft['photos'] as List).map((file) => AttachedFile.fromJson(Map<String, dynamic>.from(file))));
      if (draft['recording'] != null) _pendingRecording = AttachedFile.fromJson(Map<String, dynamic>.from(draft['recording']));
      _hasFailedTranscription = draft['failedTranscription'] == true;
      _liveTextAlreadyShown = draft['liveText'] as String? ?? '';
      _peoplePicker.restoreDraft(Map<String, dynamic>.from(draft['people'] ?? {}));
      _draftRestored = true;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppLocalizations.of(context).storyDraftSaveFailed)));
      }
    } finally {
      if (mounted) setState(() => _draftLoading = false);
    }
  }

  Future<void> _stopForDraft() async {
    _finalizingDraft = true;
    try {
      if (_recorder.state == RecorderState.recording || _recorder.canRetryStop) await _recorder.stop();
    } finally {
      _finalizingDraft = false;
    }
  }

  Future<bool> _saveDraft() async {
    await _stopForDraft();
    await LocalDraftStore.write(_draftKey, {
      'event': _currentEvent().toJson(), 'titleEdited': _titleEdited,
      'photos': _photos.map((file) => file.toJson()).toList(),
      'recording': _pendingRecording?.toJson(),
      'failedTranscription': _hasFailedTranscription, 'liveText': _liveTextAlreadyShown,
      'people': _peoplePicker.exportDraft(),
    });
    return true;
  }

  Future<void> _discardDraft() async {
    await _stopForDraft();
    await LocalDraftStore.remove(_draftKey);
  }

  String _suggestedTitle() {
    final text = _descriptionController.text.trim();
    if (text.isNotEmpty) {
      final title = text.split(RegExp(r'\s+')).take(8).join(' ');
      return title.length < text.length ? '$title…' : title;
    }
    final l10n = AppLocalizations.of(context);
    return l10n.quickAddDefaultTitle(formatDateWithPrecision(_dateTime, _datePrecision, l10n.localeName));
  }

  void _updateSuggestedTitle() {
    if (!_titleEdited && mounted) _titleController.text = _suggestedTitle();
  }

  static RecorderController _buildDefaultRecorderController(BuildContext context) {
    final auth = context.read<AuthService>();
    final db = context.read<DatabaseService>();
    final settings = context.read<AppSettingsService>();
    return RecorderController(
      audioCapture: RecordPackageAudioCapture(),
      fileStore: createRecordingFileStore(),
      database: db,
      transcriptionClient: TranscriptionClient(
        baseUrl: auth.baseUrl,
        getToken: () => auth.token,
      ),
      language: settings.effectiveRecordingLanguage,
      feedback: context.read<InteractionFeedback?>(),
    );
  }

  void _onPeopleChanged() {
    if (mounted) setState(() {});
  }

  void _onRecorderChanged() {
    if (!mounted) return;
    if (_recorder.state == RecorderState.recording || _recorder.state == RecorderState.finishing) {
      _appendLiveTranscript();
    }
    final result = _recorder.lastStopResult;
    if (_recorder.state == RecorderState.idle && result != null &&
        _pendingRecording?.id != result.attachedFile.id) {
      _pendingRecording = result.attachedFile;
      _appendLiveTranscript();
      _hasFailedTranscription = result.failedSegments.isNotEmpty;
      if (_hasFailedTranscription && !_finalizingDraft) _showTranscriptionFailure();
    }
    setState(() {});
  }

  void _appendLiveTranscript() {
    final live = _recorder.liveTranscript;
    if (live.length <= _liveTextAlreadyShown.length) return;
    final delta = live.substring(_liveTextAlreadyShown.length);
    final separator = _liveTextAlreadyShown.isEmpty && _descriptionController.text.isNotEmpty &&
        !_descriptionController.text.endsWith(' ') ? ' ' : '';
    final selection = _descriptionController.selection;
    _descriptionController.value = TextEditingValue(
      text: '${_descriptionController.text}$separator$delta', selection: selection);
    _liveTextAlreadyShown = live;
  }

  void _showTranscriptionFailure() {
    final l10n = AppLocalizations.of(context);
    final reason = _recorder.liveTranscriptionReason;
    if (reason == LiveTranscriptionReason.anonymousLimit ||
        reason == LiveTranscriptionReason.notSignedIn) {
      _showRecordingSignIn(messageForTranscriptionReason(l10n, reason));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(messageForTranscriptionReason(l10n, reason))));
  }

  void _showRecordingSignIn(String message) {
    final l10n = AppLocalizations.of(context);
    showAccountRequiredDialog(context,
        message: '$message\n\n${l10n.accountStorySavedBeforeSignIn}',
        beforeSignIn: () async {
          _finalizingDraft = true;
          try {
            if (_recorder.state == RecorderState.recording || _recorder.canRetryStop) {
              await _recorder.stop();
            }
            if (!mounted) return false;
            if (_titleController.text.trim().isEmpty &&
                _descriptionController.text.trim().isEmpty &&
                _pendingRecording == null && _photos.isEmpty &&
                _participantIds.isEmpty && _placeId == null) {
              return true;
            }
            return _save(close: false);
          } catch (_) {
            return false;
          } finally {
            _finalizingDraft = false;
          }
        });
  }

  @override
  void dispose() {
    _recorder.removeListener(_onRecorderChanged);
    if (_ownsRecorder) {
      _recorder.dispose();
    }
    _titleController.dispose();
    _peoplePicker.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _toggleRecording() async {
    final stopping = _recorder.state == RecorderState.recording || _recorder.canRetryStop;
    try {
      if (stopping) {
        await _recorder.stop();
        return;
      }

      _liveTextAlreadyShown = '';
      await _recorder.start();
      if (mounted && _recorder.liveTranscriptionReason == LiveTranscriptionReason.anonymousLimit) {
        _showTranscriptionFailure();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(stopping ? AppLocalizations.of(context).storyRecordingStopFailed : AppLocalizations.of(context).micOtherError),
        action: SnackBarAction(label: stopping ? AppLocalizations.of(context).storyRetryFinish : AppLocalizations.of(context).commonRetry,
          onPressed: _toggleRecording)));
      }
    }
  }

  Future<void> _pickPhotos() async {
    setState(() => _isPickingPhotos = true);
    try {
      final photos = await StoryPhotoService(context.read<DatabaseService>())
          .pickPhotos(_draftEvent.id);
      if (mounted) setState(() => _photos.addAll(photos));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text(AppLocalizations.of(context).storyPhotoImportFailed)),
        );
      }
    } finally {
      if (mounted) setState(() => _isPickingPhotos = false);
    }
  }

  Future<void> _selectDateTime() async {
    final date = await pickStoryDate(context, _dateTime, _datePrecision);
    if (date != null && mounted) {
      setState(() {
      _dateTime = date;
      _updateSuggestedTitle();
    });
    }
  }

  Future<void> _transcribeNow() async {
    final recording = _pendingRecording;
    if (recording == null || _isTranscribingNow) return;
    setState(() => _isTranscribingNow = true);
    try {
      final result = await _recorder.transcribeStoredRecording(recording.id);
      recording.transcriptSlices = result.transcriptSlices;
      if (!mounted) return;
      _hasFailedTranscription = result.failedSegments.isNotEmpty;
      if (result.transcript.isNotEmpty) {
        final current = _descriptionController.text;
        final previous = _liveTextAlreadyShown;
        if (previous.isNotEmpty && current.endsWith(previous)) {
          _descriptionController.text = current.substring(0, current.length - previous.length) + result.transcript;
        } else if (!current.contains(result.transcript)) {
          _descriptionController.text = [current.trim(), result.transcript].where((part) => part.isNotEmpty).join(' ');
        }
        _liveTextAlreadyShown = result.transcript;
      }
      if (_hasFailedTranscription) _showTranscriptionFailure();
    } catch (_) {
      if (mounted) {
        _hasFailedTranscription = true;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).liveTranscriptionFailing)));
      }
    } finally {
      if (mounted) setState(() => _isTranscribingNow = false);
    }
  }

  bool get _canSave =>
      !_isSaving &&
      !_recorder.canRetryStop &&
      !_isPickingPhotos &&
      !_draftLoading &&
      !_isTranscribingNow &&
      (_recorder.state == RecorderState.idle ||
          _recorder.state == RecorderState.failed);

  Future<bool> _save({bool close = true}) async {
    if (!_canSave) return false;
    if (_titleController.text.trim().isEmpty) _titleController.text = _suggestedTitle();
    if (close && !_formKey.currentState!.validate()) return false;

    var title = _titleController.text.trim();

    setState(() => _isSaving = true);

    try {
      final db = context.read<DatabaseService>();
      final detectedIds = await saveStoryPeople(db, await _peoplePicker.peopleForSave());
      final participantIds = {..._participantIds, ...detectedIds}.toList();
      final event = _currentEvent(title: title, participants: participantIds);

      await db.saveEvent(event);
      await _peoplePicker.saveInformation(event);

      final pending = _pendingRecording;
      if (pending != null) {
        final recording = await db.getLocalRecording(pending.id);
        if (recording != null) {
          await db.saveLocalRecording(recording.copyWith(eventId: event.id));
        }
      }

      await LocalDraftStore.remove(_draftKey);
      _draftRestored = false;
      _initialContent = jsonEncode(_currentEvent().toJson());
      if (mounted) context.read<InteractionFeedback?>()?.play(FeedbackCue.success);
      if (mounted && close) {
        final l10n = AppLocalizations.of(context);
        Navigator.pop(
            context, true); // Return true to indicate save was successful
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(l10n.addEventSavedSnackbar(
                  event.title,
                  widget.existingEvent != null
                      ? l10n.addEventSavedActionUpdated
                      : l10n.addEventSavedActionCreated))),
        );
      }
      return true;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context).storySaveFailed)));
      }
      return false;
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toString();
    final participantCount = {..._participantIds, ..._peoplePicker.selectedPeople.map((p) => p.id)}.length;
    return UnsavedDraftGuard(
      key: _draftGuard,
      isDirty: () => _hasUnsavedContent,
      isBusy: () => _isSaving || _isTranscribingNow || _draftLoading || _isPickingPhotos ||
        _recorder.state == RecorderState.finishing || _recorder.state == RecorderState.requestingPermission,
      onSaveDraft: _saveDraft, onDiscard: _discardDraft,
      child: Scaffold(
      appBar: AppBar(
        title: Text(widget.existingEvent != null ? l10n.addEventTitleEdit : l10n.addEventTitleNew),
        actions: [
          TextButton(
            onPressed: _canSave ? _save : null,
            child: _isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(l10n.commonSave),
          ),
        ],
      ),
      body: _draftLoading ? const Center(child: CircularProgressIndicator()) : Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_draftRestored) Text(l10n.storyDraftRestored),
            Text(l10n.storyAudioFirstTitle,
                style: Theme.of(context).textTheme.titleMedium),
            Text(l10n.storyAudioFirstHelp),
            const SizedBox(height: 8),
            _buildRecordingCard(l10n),
            const SizedBox(height: 16),
            TextFormField(
              controller: _descriptionController,
              contextMenuBuilder: (context, editable) => diaCorrectionTextMenu(
                  context, editable,
                  recordings: _recorder.state == RecorderState.idle && !_isTranscribingNow
                      ? [..._draftEvent.files, if (_pendingRecording != null) _pendingRecording!]
                          .where((file) => file.isRecording).toList()
                      : [],
                  store: _recorder.fileStore,
                  regionSuggestion: _suggestDiaRegion),
              decoration: InputDecoration(
                  labelText: l10n.addEventDescriptionLabel, prefixIcon: const Icon(Icons.note)),
              maxLines: 3,
            ),
            const SizedBox(height: 16),
            TranscriptPeoplePicker(controller: _peoplePicker, selectedIds: _participantIds.toSet()),
            const SizedBox(height: 16),
            TextFormField(
              controller: _titleController,
              onChanged: (_) => _titleEdited = true,
              decoration: InputDecoration(
                  helperText: !_titleEdited ? l10n.storyTitleSuggestion : null,
                  labelText: l10n.addEventTitleFieldLabel, prefixIcon: const Icon(Icons.title)),
              validator: (v) =>
                  v == null || v.trim().isEmpty ? l10n.addEventTitleRequired : null,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<EventType>(
              initialValue: _type,
              decoration: InputDecoration(
                  labelText: l10n.addEventTypeLabel, prefixIcon: const Icon(Icons.category)),
              items: EventType.values
                  .map((t) => DropdownMenuItem(value: t, child: Text(eventTypeLabel(l10n, t))))
                  .toList(),
              onChanged: (v) => setState(() => _type = v ?? EventType.other),
            ),
            const SizedBox(height: 16),
            InputDecorator(
              decoration: InputDecoration(labelText: l10n.storyDatePrecision),
              child: DropdownButtonHideUnderline(child: DropdownButton<DatePrecision>(
              value: _datePrecision,
              isExpanded: true,
              items: [
                DropdownMenuItem(value: DatePrecision.year, child: Text(l10n.quickAddAYear)),
                DropdownMenuItem(value: DatePrecision.month, child: Text(l10n.quickAddMonthAndYear)),
                DropdownMenuItem(value: DatePrecision.day, child: Text(l10n.quickAddExactDate)),
                DropdownMenuItem(value: DatePrecision.time, child: Text(l10n.storyExactTime)),
              ],
              onChanged: (value) async {
                if (value == null) return;
                final date = await pickStoryDate(context, _dateTime, value);
                if (date != null && mounted) setState(() { _datePrecision = value; _dateTime = date; _updateSuggestedTitle(); });
              },
            ))),
            ListTile(
              leading: const Icon(Icons.schedule),
              title: Text(formatDateWithPrecision(_dateTime, _datePrecision, locale)),
              subtitle: Text(l10n.addEventStartTimeSubtitle),
              onTap: _selectDateTime,
            ),
            ListTile(
              leading: const Icon(Icons.schedule_outlined),
              title: Text(_endDateTime != null
                  ? DateFormat.yMMMd(locale).add_jm().format(_endDateTime!)
                  : l10n.addEventNoEndTime),
              subtitle: Text(l10n.addEventEndTimeSubtitle),
              trailing: _endDateTime != null
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(() => _endDateTime = null))
                  : null,
              onTap: _selectEndDateTime,
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _isPickingPhotos || _isSaving ? null : _pickPhotos,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: Text(l10n.storyAddPhotos),
            ),
            Text(l10n.storyPhotosLocal,
                style: Theme.of(context).textTheme.bodySmall),
            if ([..._draftEvent.files, ..._photos].any((file) => file.isImage))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final file in [..._draftEvent.files, ..._photos])
                    if (file.isImage) StoryPhoto(file: file),
                ]),
              ),
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                leading: const Icon(Icons.people),
                title: Text(participantCount == 0
                    ? l10n.addEventAddParticipants
                    : l10n.addEventParticipantsCount(participantCount)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _selectParticipants(),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.place),
                title: Text(_placeId == null
                    ? l10n.addEventAddLocation
                    : l10n.addEventLocationSelected),
                trailing: _placeId != null
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(() => _placeId = null))
                    : const Icon(Icons.chevron_right),
                onTap: () => _selectPlace(),
              ),
            ),
          ],
        ),
      ),
    ));
  }

  Widget _buildRecordingCard(AppLocalizations l10n) {
    final state = _recorder.state;
    final isRecording = state == RecorderState.recording;
    final isBusy = state == RecorderState.requestingPermission ||
        state == RecorderState.finishing || _isTranscribingNow;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  icon: Icon(
                    isRecording ? Icons.stop_circle : _recorder.canRetryStop ? Icons.refresh : Icons.mic,
                    color: isRecording ? Colors.red : null,
                  ),
                  tooltip: isRecording ? l10n.quickAddStopRecording : _recorder.canRetryStop ? l10n.storyRetryFinish : l10n.quickAddStartRecording,
                  iconSize: 36,
                  onPressed: isBusy ? null : _toggleRecording,
                ),
                const SizedBox(width: 8),
                Flexible(child: Text(isRecording ? l10n.quickAddStopRecording
                    : _recorder.canRetryStop ? l10n.storyRetryFinish : l10n.quickAddStartRecording)),
                const SizedBox(width: 8),
                Text(_formatElapsed(_recorder.elapsed)),
                const SizedBox(width: 16),
                if (isRecording)
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: _recorder.inputLevel.clamp(0.0, 1.0),
                        minHeight: 8,
                      ),
                    ),
                  ),
              ],
            ),
            if (state == RecorderState.failed && _recorder.failure != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _recorder.canRetryStop ? l10n.storyRecordingStopFailed : messageForMicFailure(l10n, _recorder.failure!.reason),
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            if (isRecording && !_recorder.isTranscribing)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  messageForTranscriptionReason(l10n, _recorder.liveTranscriptionReason),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (_recorder.isTranscribing || state == RecorderState.finishing || _isTranscribingNow)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 8),
                    Flexible(child: Text(l10n.quickAddTranscribing)),
                  ],
                ),
              ),
            if (_recorder.showGuestTranscriptionWarning &&
                _recorder.liveTranscriptionReason != LiveTranscriptionReason.anonymousLimit)
              Text(l10n.recordingGuestTranscriptionWarning,
                  style: Theme.of(context).textTheme.bodySmall),
            if (!isRecording && _recorder.liveTranscriptionReason == LiveTranscriptionReason.anonymousLimit)
              Text(l10n.liveTranscriptionAnonymousLimit),
            if (!isRecording && _recorder.liveTranscriptionReason == LiveTranscriptionReason.dailyLimit)
              Text(l10n.liveTranscriptionDailyLimit),
            if (_recorder.showGuestTranscriptionWarning ||
                _recorder.liveTranscriptionReason == LiveTranscriptionReason.anonymousLimit)
              TextButton(
                onPressed: isBusy ? null : () => _showRecordingSignIn(
                    _recorder.liveTranscriptionReason == LiveTranscriptionReason.anonymousLimit
                        ? l10n.liveTranscriptionAnonymousLimit : l10n.recordingGuestTranscriptionWarning),
                child: Text(l10n.loginAccountButton)),
            if (_pendingRecording != null && _recorder.state == RecorderState.idle && !_isTranscribingNow)
              DiaCorrectionButton(file: _pendingRecording!, store: _recorder.fileStore,
                  regionSuggestion: _suggestDiaRegion,
                  transcriptController: _descriptionController),
            if (_pendingRecording != null && !isRecording &&
                (_hasFailedTranscription || _descriptionController.text.trim().isEmpty))
              TextButton(onPressed: isBusy ? null : _transcribeNow,
                child: Text(l10n.quickAddTranscribeNow)),
            if (_pendingRecording != null && !isRecording)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  l10n.recordingAttachedWithDuration(_formatElapsed(
                      Duration(milliseconds: _pendingRecording!.durationMs ?? 0))),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _formatElapsed(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    return hours > 0
        ? '${two(hours)}:${two(minutes)}:${two(seconds)}'
        : '${two(minutes)}:${two(seconds)}';
  }

  Future<void> _selectEndDateTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _endDateTime ?? _dateTime,
      firstDate: _dateTime,
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: _endDateTime != null
          ? TimeOfDay.fromDateTime(_endDateTime!)
          : TimeOfDay.fromDateTime(_dateTime.add(const Duration(hours: 1))),
    );
    if (time == null) return;

    setState(() {
      _endDateTime =
          DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  Future<void> _selectParticipants() async {
    try {
    final l10n = AppLocalizations.of(context);
    final db = context.read<DatabaseService>();
    final persons = await db.getPersons();

    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.addEventSelectParticipantsTitle),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: persons
                .map((p) => CheckboxListTile(
                      title: Text(p.name),
                      value: _participantIds.contains(p.id) || _peoplePicker.selectedPeople.any((person) => person.id == p.id),
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            _participantIds.add(p.id);
                          } else {
                            _participantIds.remove(p.id);
                            _peoplePicker.dismiss(p.name);
                          }
                        });
                        _peoplePicker.preferPersonIds(_participantIds.toSet());
                        Navigator.pop(context);
                      },
                    ))
                .toList(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.addEventDone))
        ],
      ),
    );
    setState(() {});
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppLocalizations.of(context).storySaveFailed),
        action: SnackBarAction(label: AppLocalizations.of(context).commonRetry,
          onPressed: _selectParticipants)));
      }
    }
  }

  Future<DiaRegion?> _suggestDiaRegion() async {
    final place = _placeId == null ? null
        : await context.read<DatabaseService>().getPlace(_placeId!);
    return suggestDiaRegion(selectedPosition: place == null ? null
        : LatLng(place.latitude, place.longitude));
  }

  Future<void> _selectPlace() async {
    try {
    final l10n = AppLocalizations.of(context);
    final db = context.read<DatabaseService>();
    final places = await db.getPlaces();

    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.addEventSelectPlaceTitle),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.map_outlined),
                title: Text(l10n.addEventPickOnMap),
                onTap: () {
                  Navigator.pop(context);
                  _pickPlaceOnMap(db, places);
                },
              ),
              const Divider(height: 1),
              ...places.map((p) => ListTile(
                    title: Text(p.name),
                    subtitle: p.address != null ? Text(p.address!) : null,
                    onTap: () {
                      setState(() => _placeId = p.id);
                      Navigator.pop(context);
                    },
                  )),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.commonCancel))
        ],
      ),
    );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppLocalizations.of(context).storySaveFailed),
        action: SnackBarAction(label: AppLocalizations.of(context).commonRetry,
          onPressed: _selectPlace)));
      }
    }
  }

  /// The "pick on map" action: opens the same [LocationPickerScreen] the
  /// quick add sheet and place sheet use, then either proposes an existing
  /// place within 50m (see [findNearbyPlace]) or creates a new one with a
  /// sensible default name at that spot.
  Future<void> _pickPlaceOnMap(DatabaseService db, List<Place> places) async {
    try {
    final initialPlace = places.firstWhere(
      (p) => p.id == _placeId,
      // Central Europe: same fallback as the map's own default view (see
      // MapScreenState._defaultCenter) for when there's nothing more
      // specific to center on.
      orElse: () => Place(name: '', latitude: 50, longitude: 10),
    );
    final position = await Navigator.push<LatLng>(
      context,
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          initialPosition: LatLng(initialPlace.latitude, initialPlace.longitude),
        ),
      ),
    );
    if (position == null || !mounted) return;

    final nearby = findNearbyPlace(places, position);
    if (nearby != null) {
      final l10n = AppLocalizations.of(context);
      final useExisting = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.addEventUseNearbyPlaceTitle),
          content: Text(l10n.addEventUseNearbyPlaceBody(nearby.name)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false), child: Text(l10n.addEventNewPlace)),
            FilledButton(
                onPressed: () => Navigator.pop(context, true), child: Text(l10n.addEventUseIt)),
          ],
        ),
      );
      if (useExisting == true) {
        setState(() => _placeId = nearby.id);
        return;
      }
    }

    if (!mounted) return;
    final name = await resolveDefaultPlaceName(position, AppLocalizations.of(context));
    if (!mounted) return;
    final place = Place(
      name: name,
      latitude: position.latitude,
      longitude: position.longitude,
    );
    await db.savePlace(place);
    if (mounted) setState(() => _placeId = place.id);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppLocalizations.of(context).storySaveFailed),
        action: SnackBarAction(label: AppLocalizations.of(context).commonRetry,
          onPressed: () => _pickPlaceOnMap(db, places))));
      }
    }
  }


}
