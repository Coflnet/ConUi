import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../models/models.dart';
import '../../services/app_settings_service.dart';
import '../../services/audio_capture.dart';
import '../../services/auth_service.dart';
import '../../services/database_service.dart';
import '../../widgets/account_required_dialog.dart';
import '../../services/person_mentions.dart';
import '../../widgets/transcript_people_picker.dart';
import '../../services/story_photo_service.dart';
import '../../services/local_draft_store.dart';
import '../../services/interaction_feedback.dart';
import '../../widgets/unsaved_draft_guard.dart';
import '../../widgets/story_date_picker.dart';
import '../map/location_picker_screen.dart';
import '../../widgets/story_photo.dart';
import '../../services/record_package_audio_capture.dart';
import '../../services/recorder_controller.dart';
import '../../services/recording_file_store.dart';
import '../../services/transcription_client.dart';
import '../map/nearby_place.dart';

/// Localized messages shared between anything driving a [RecorderController]
/// (the quick add sheet, the add/edit story form) - kept in one place so the
/// two screens read identically instead of drifting apart.
String messageForTranscriptionReason(AppLocalizations l10n, LiveTranscriptionReason reason) {
  switch (reason) {
    case LiveTranscriptionReason.notStarted:
      return l10n.liveTranscriptionNotStarted;
    case LiveTranscriptionReason.working:
      return l10n.liveTranscriptionWorking;
    case LiveTranscriptionReason.offline:
      return l10n.liveTranscriptionOffline;
    case LiveTranscriptionReason.notSignedIn:
      return l10n.liveTranscriptionNotSignedIn;
    case LiveTranscriptionReason.anonymousLimit:
      return l10n.liveTranscriptionAnonymousLimit;
    case LiveTranscriptionReason.notConfigured:
      return l10n.liveTranscriptionNotConfigured;
    case LiveTranscriptionReason.failing:
      return l10n.liveTranscriptionFailing;
  }
}

String messageForMicFailure(AppLocalizations l10n, AudioCaptureFailureReason reason) {
  switch (reason) {
    case AudioCaptureFailureReason.permissionDenied:
      return l10n.micPermissionDenied;
    case AudioCaptureFailureReason.noMicrophone:
      return l10n.micNoMicrophone;
    case AudioCaptureFailureReason.other:
      return l10n.micOtherError;
  }
}

/// One entry in the "who was there" list: either an existing [Person], or a
/// typed name that will become a brand-new [Person] on save.
class PersonPick {
  final Person? existing;
  final String? newName;

  const PersonPick.existing(Person person)
      : existing = person,
        newName = null;

  const PersonPick.newName(String name)
      : existing = null,
        newName = name;

  String get displayName => existing?.name ?? newName!;
}

class QuickAddResult {
  final Event event;
  final Place place;

  const QuickAddResult({required this.event, required this.place});
}

/// One sheet to record (or type) a story, pick who was involved and when,
/// optionally name the place, and save - all in a single step. See the
/// class-level rules in the project brief: recording is always one tap
/// away and never blocks; live transcript text is appended, never
/// overwriting what the user typed; only text or a recording is required
/// to save; closing with unsaved content asks first, and an in-progress or
/// abandoned recording is always kept (never silently deleted).
class QuickAddSheet extends StatefulWidget {
  /// Where the story's place should be, read live from this notifier so a
  /// pin the user drags on the map behind the sheet updates the position
  /// used at save time (see [DraggablePinMarker]).
  final ValueNotifier<LatLng> position;

  /// When set, the sheet is pinned to this already-existing place (e.g.
  /// opened via its "Add story here" action) instead of proposing or
  /// creating one from [position].
  final Place? initialPlace;

  /// Overridable for tests, so a fake can be driven without a real
  /// microphone or backend.
  final RecorderController? recorderController;

  const QuickAddSheet({
    super.key,
    required this.position,
    this.initialPlace,
    this.recorderController,
  });

  /// Opens the sheet as a scrollable modal bottom sheet. Returns the
  /// created story and place, or null if the user cancelled/discarded.
  static Future<QuickAddResult?> show(
    BuildContext context, {
    required ValueNotifier<LatLng> position,
    Place? initialPlace,
  }) {
    return showModalBottomSheet<QuickAddResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: false,
      enableDrag: false,
      builder: (context) => QuickAddSheet(position: position, initialPlace: initialPlace),
    );
  }

  @override
  State<QuickAddSheet> createState() => QuickAddSheetState();
}

class QuickAddSheetState extends State<QuickAddSheet> {
  final _textController = TextEditingController();
  final _placeNameController = TextEditingController();
  final _titleController = TextEditingController();
  final _personSearchController = TextEditingController();

  final List<PersonPick> _selectedPersons = [];
  late final TranscriptPeopleController _peoplePicker;
  List<Person> _allPersons = [];
  List<Place> _allPlaces = [];
  Place? _nearbyPlace;
  Place? _useExistingPlace;
  Place? _savedDraftPlace;
  String? _suggestedPlaceName;
  LatLng? _suggestedPosition;

  DateTime _date = DateTime.now();
  DatePrecision _datePrecision = DatePrecision.day;

  late final RecorderController _recorder;
  bool _ownsRecorder = false;
  AttachedFile? _pendingRecording;
  String _liveTextAlreadyShown = '';
  bool _isSaving = false;
  bool _isPickingPhotos = false;
  Event _draftEvent = Event(title: '', dateTime: DateTime.now());
  final List<AttachedFile> _photos = [];
  bool _isTranscribingNow = false;
  bool _hasFailedTranscription = false;
  bool _loadedLookups = false;
  bool _lookupFailed = false;
  bool _draftLoading = true;
  bool _draftRestored = false;
  bool _finalizingDraft = false;
  bool _placePinned = false;
  bool _positionChanged = false;
  final _draftGuard = GlobalKey<UnsavedDraftGuardState>();
  String get _draftKey => 'quick-story:${widget.initialPlace?.id ?? "new"}';

  @override
  void initState() {
    super.initState();
    _peoplePicker = TranscriptPeopleController(_textController, context.read<DatabaseService>());
    if (widget.recorderController != null) {
      _recorder = widget.recorderController!;
    } else {
      _recorder = _buildDefaultRecorderController(context);
      _ownsRecorder = true;
    }
    _recorder.addListener(_onRecorderChanged);
    if (widget.initialPlace != null) {
      _placePinned = true;
      _useExistingPlace = widget.initialPlace;
      _placeNameController.text = widget.initialPlace!.name;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _restoreDraft();
      if (mounted) _loadLookups();
    });
  }

  Future<void> _restoreDraft() async {
    try {
      final draft = await LocalDraftStore.read(_draftKey);
      if (!mounted || draft == null) return;
      _draftEvent = Event.fromJson(Map<String, dynamic>.from(draft['event']));
      _textController.text = _draftEvent.description ?? '';
      _titleController.text = _draftEvent.title;
      _date = _draftEvent.dateTime;
      _datePrecision = _draftEvent.datePrecision;
      _photos.addAll((draft['photos'] as List).map((file) => AttachedFile.fromJson(Map<String, dynamic>.from(file))));
      if (draft['recording'] != null) _pendingRecording = AttachedFile.fromJson(Map<String, dynamic>.from(draft['recording']));
      _hasFailedTranscription = draft['failedTranscription'] == true;
      _liveTextAlreadyShown = draft['liveText'] as String? ?? '';
      _placeNameController.text = draft['placeName'] as String? ?? '';
      if (draft['place'] != null) _useExistingPlace = Place.fromJson(Map<String, dynamic>.from(draft['place']));
      _placePinned = draft['placePinned'] == true;
      _positionChanged = draft['positionChanged'] == true;
      widget.position.value = LatLng(draft['latitude'], draft['longitude']);
      _selectedPersons.addAll((draft['persons'] as List).map((pick) => pick['person'] != null
        ? PersonPick.existing(Person.fromJson(Map<String, dynamic>.from(pick['person'])))
        : PersonPick.newName(pick['name'] as String)));
      _peoplePicker.restoreDraft(Map<String, dynamic>.from(draft['people'] ?? {}));
      _draftRestored = true;
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).storyDraftSaveFailed)));
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
      'event': Event(id: _draftEvent.id, title: _titleController.text,
        description: _textController.text, dateTime: _date, datePrecision: _datePrecision).toJson(),
      'photos': _photos.map((file) => file.toJson()).toList(),
      'recording': _pendingRecording?.toJson(), 'failedTranscription': _hasFailedTranscription,
      'liveText': _liveTextAlreadyShown, 'placeName': _placeNameController.text,
      'place': _useExistingPlace?.toJson(), 'placePinned': _placePinned, 'positionChanged': _positionChanged,
      'latitude': widget.position.value.latitude, 'longitude': widget.position.value.longitude,
      'persons': _selectedPersons.map((pick) => {'person': pick.existing?.toJson(), 'name': pick.newName}).toList(),
      'people': _peoplePicker.exportDraft(),
    });
    return true;
  }

  Future<void> _discardDraft() async {
    await _stopForDraft();
    await LocalDraftStore.remove(_draftKey);
  }

  Future<void> _changePosition() async {
    final place = _useExistingPlace;
    final point = await Navigator.push<LatLng>(context, MaterialPageRoute(builder: (_) =>
      LocationPickerScreen(initialPosition: place == null ? widget.position.value : LatLng(place.latitude, place.longitude))));
    if (point == null || !mounted) return;
    setState(() {
      _placePinned = false;
      if (place != null && _placeNameController.text == place.name) _placeNameController.clear();
      _positionChanged = true;
      _useExistingPlace = null;
      widget.position.value = point;
      _updateNearbyPlace(point);
      _suggestedPlaceName = null;
      _suggestedPosition = null;
    });
    final name = await resolveDefaultPlaceName(point, AppLocalizations.of(context));
    if (mounted && widget.position.value == point) {
      setState(() {
      _suggestedPosition = point;
      _suggestedPlaceName = name;
    });
    }
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

  Future<void> _loadLookups() async {
    final db = context.read<DatabaseService>();
    try {
    final persons = await db.getPersons();
    final places = await db.getPlaces();
    if (!mounted) return;
    setState(() {
      _allPersons = persons;
      _allPlaces = places;
      _loadedLookups = true;
      _lookupFailed = false;
      _updateNearbyPlace(widget.position.value);
    });
    final point = widget.position.value;
    final name =
        await resolveDefaultPlaceName(point, AppLocalizations.of(context));
    if (!mounted) return;
    setState(() {
      _suggestedPosition = point;
      _suggestedPlaceName = name;
    });
    } catch (_) {
      if (mounted) setState(() => _lookupFailed = true);
    }
  }

  void _updateNearbyPlace(LatLng point) {
    _nearbyPlace = findNearbyPlace(_allPlaces, point);
    // Don't second-guess a place the sheet was explicitly opened for (e.g.
    // the place sheet's "Add story here"); only clear an existing-place
    // choice the user made themselves via the nearby-place proposal.
    if (!_placePinned && _nearbyPlace == null && _useExistingPlace != null) {
      _useExistingPlace = null;
    }
  }

  void _onRecorderChanged() {
    if (!mounted) return;
    if (_recorder.state == RecorderState.recording ||
        _recorder.state == RecorderState.finishing) {
      _appendLiveTranscriptDelta();
    }
    final result = _recorder.lastStopResult;
    if (_recorder.state == RecorderState.idle && result != null &&
        _pendingRecording?.id != result.attachedFile.id) {
      _pendingRecording = result.attachedFile;
      _hasFailedTranscription = result.failedSegments.isNotEmpty;
      if (_hasFailedTranscription && !_finalizingDraft) _showTranscriptionFailure(result.failedSegments.length);
    }
    setState(() {});
  }

  /// Appends only the NEW part of the live transcript to the text field,
  /// at the end, without disturbing the user's own cursor position or
  /// anything they've typed elsewhere in the field - the sheet must never
  /// clobber typed text with live dictation. See the class doc comment.
  void _appendLiveTranscriptDelta() {
    final live = _recorder.liveTranscript;
    if (live.length <= _liveTextAlreadyShown.length) return;
    final delta = live.substring(_liveTextAlreadyShown.length);
    final firstDelta = _liveTextAlreadyShown.isEmpty;
    _liveTextAlreadyShown = live;
    if (delta.isEmpty) return;

    final controller = _textController;
    final oldSelection = controller.selection;
    final separator = firstDelta &&
            controller.text.isNotEmpty &&
            !controller.text.endsWith(' ')
        ? ' '
        : '';
    final newText = '${controller.text}$separator$delta';
    final newSelection = oldSelection.isValid
        ? oldSelection
        : TextSelection.collapsed(offset: newText.length);
    controller.value = TextEditingValue(text: newText, selection: newSelection);
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
        _showTranscriptionFailure(0);
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

  void _showTranscriptionFailure(int failedCount) {
    final l10n = AppLocalizations.of(context);
    final reason = _recorder.liveTranscriptionReason;
    if (reason == LiveTranscriptionReason.anonymousLimit ||
        reason == LiveTranscriptionReason.notSignedIn) {
      showAccountRequiredDialog(context,
          message: '${messageForTranscriptionReason(l10n, reason)}\n\n${l10n.accountStorySavedBeforeSignIn}',
          beforeSignIn: () async => !_hasUnsavedContent || await _save(close: false));
      return;
    }
    final message = reason == LiveTranscriptionReason.notConfigured ||
            reason == LiveTranscriptionReason.offline
        ? messageForTranscriptionReason(l10n, reason)
        : l10n.recordingPartsFailedLive(failedCount);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _transcribeNow() async {
    final recordingId = _pendingRecording?.id;
    if (recordingId == null || _isTranscribingNow) return;
    setState(() => _isTranscribingNow = true);
    try {
      final result = await _recorder.transcribeStoredRecording(recordingId);
      if (!mounted) return;
      _hasFailedTranscription = result.failedSegments.isNotEmpty;
      if (result.transcript.isNotEmpty) {
        final current = _textController.text;
        if (_liveTextAlreadyShown.isNotEmpty && current.endsWith(_liveTextAlreadyShown)) {
          _textController.text = current.substring(0, current.length - _liveTextAlreadyShown.length) + result.transcript;
        } else if (!current.contains(result.transcript)) {
          _textController.text = [current.trim(), result.transcript].where((part) => part.isNotEmpty).join(' ');
        }
        _liveTextAlreadyShown = result.transcript;
      }
      if (_hasFailedTranscription) {
        _showTranscriptionFailure(result.failedSegments.length);
      }
    } catch (_) {
      if (!mounted) return;
      _hasFailedTranscription = true;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(AppLocalizations.of(context).liveTranscriptionFailing)));
    } finally {
      if (mounted) setState(() => _isTranscribingNow = false);
    }
  }

  void _selectExistingPerson(Person person) {
    setState(() {
      _selectedPersons.removeWhere((pick) => pick.existing == null &&
          [person.name, ...person.aliases].any((name) => normalizedPersonName(name) == normalizedPersonName(pick.displayName)));
      if (!_selectedPersons.any((pick) => pick.existing?.id == person.id)) {
        _selectedPersons.add(PersonPick.existing(person));
      }
      _peoplePicker.preferPersonIds(_selectedPersons.where((p) => p.existing != null).map((p) => p.existing!.id).toSet());
      _personSearchController.clear();
    });
  }

  void _addNewPersonName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    setState(() {
      if (!_selectedPersons.any((pick) => normalizedPersonName(pick.displayName) == normalizedPersonName(trimmed))) {
        _selectedPersons.add(PersonPick.newName(trimmed));
      }
      _personSearchController.clear();
    });
  }

  void _removePerson(PersonPick pick) {
    _peoplePicker.dismiss(pick.displayName);
    setState(() {
      _selectedPersons.remove(pick);
      _peoplePicker.preferPersonIds(_selectedPersons.where((p) => p.existing != null).map((p) => p.existing!.id).toSet());
    });
  }

  void _useNearbyPlace() {
    setState(() {
      _useExistingPlace = _nearbyPlace;
      _placeNameController.text = _nearbyPlace!.name;
    });
  }

  void _clearExistingPlaceChoice() {
    setState(() {
      _placePinned = false;
      _useExistingPlace = null;
      _placeNameController.clear();
    });
  }

  void _pickToday() {
    final now = DateTime.now();
    setState(() {
      _date = DateTime(now.year, now.month, now.day);
      _datePrecision = DatePrecision.day;
    });
  }

  Future<void> _pickDate(DatePrecision precision) async {
    final picked = await pickStoryDate(context, _date, precision);
    if (picked != null && mounted) {
      setState(() {
      _date = picked;
      _datePrecision = precision;
    });
    }
  }

  bool get _hasUnsavedContent =>
      _draftRestored || _positionChanged || _peoplePicker.hasDraftDecisions ||
      _textController.text.trim().isNotEmpty ||
      _pendingRecording != null ||
      _photos.isNotEmpty ||
      _recorder.state == RecorderState.recording ||
      _selectedPersons.isNotEmpty ||
      (_placeNameController.text.trim().isNotEmpty &&
        (!_placePinned || _placeNameController.text != widget.initialPlace?.name)) ||
      _titleController.text.trim().isNotEmpty ||
      _datePrecision != DatePrecision.day || !_isSameDay(_date, DateTime.now());

  /// Evaluate the same guard for both the sheet's close button and back.
  /// Explicit draft save/discard finalizes capture; Keep editing leaves it running.
  Future<bool> confirmDiscardIfNeeded() async {
    return await _draftGuard.currentState!.confirm();
  }

  String _deriveTitle(AppLocalizations l10n, String text, String placeName) {
    final explicit = _titleController.text.trim();
    if (explicit.isNotEmpty) return explicit;

    final trimmedText = text.trim();
    if (trimmedText.isNotEmpty) {
      final words = trimmedText.split(RegExp(r'\s+'));
      final firstFew = words.take(8).join(' ');
      return firstFew.length < trimmedText.length ? '$firstFew…' : firstFew;
    }
    if (placeName.trim().isNotEmpty) return placeName.trim();
    return l10n
        .quickAddDefaultTitle(DateFormat.yMMMd(l10n.localeName).format(_date));
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
    final l10n = AppLocalizations.of(context);
    final text = _textController.text.trim();
    if (close && text.isEmpty && _pendingRecording == null && _photos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.quickAddNeedsTextOrRecording)));
      return false;
    }

    setState(() => _isSaving = true);
    try {
      final db = context.read<DatabaseService>();
      final position = widget.position.value;

      Place place;
      if (_useExistingPlace != null) {
        place = _useExistingPlace!;
      } else {
        final name = _placeNameController.text.trim().isNotEmpty
            ? _placeNameController.text.trim()
            : _suggestedPosition == position && _suggestedPlaceName != null
                ? _suggestedPlaceName!
                : await resolveDefaultPlaceName(position, l10n);
        if (!mounted) return false;
        place = _savedDraftPlace?.copyWith(name: name,
                latitude: position.latitude, longitude: position.longitude) ??
            Place(name: name, latitude: position.latitude, longitude: position.longitude);
        await db.savePlace(place);
        _savedDraftPlace = place;
      }

      final participantIds = await saveStoryPeople(db, [
        for (final pick in _selectedPersons) pick.existing ?? Person(name: pick.newName!),
        ...await _peoplePicker.peopleForSave(),
      ]);

      final files = <AttachedFile>[
        if (_pendingRecording != null) _pendingRecording!,
        ..._photos
      ];
      final event = Event(
        id: _draftEvent.id,
        title: _deriveTitle(l10n, text, place.name),
        description: text.isEmpty ? null : text,
        dateTime: _date,
        datePrecision: _datePrecision,
        placeId: place.id,
        participantIds: participantIds,
        files: files,
      );
      await db.saveEvent(event);
      await _peoplePicker.saveInformation(event);

      final pendingId = _pendingRecording?.id;
      if (pendingId != null) {
        final recording = await db.getLocalRecording(pendingId);
        if (recording != null) {
          await db.saveLocalRecording(recording.copyWith(eventId: event.id));
        }
      }

      await LocalDraftStore.remove(_draftKey);
      _draftRestored = false;
      if (!mounted) return false;
      context.read<InteractionFeedback?>()?.play(FeedbackCue.success);
      if (close) Navigator.pop(context, QuickAddResult(event: event, place: place));
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
  void dispose() {
    _recorder.removeListener(_onRecorderChanged);
    if (_ownsRecorder) {
      _recorder.dispose();
    }
    _peoplePicker.dispose();
    _textController.dispose();
    _placeNameController.dispose();
    _titleController.dispose();
    _personSearchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return UnsavedDraftGuard(
      key: _draftGuard,
      isDirty: () => _hasUnsavedContent,
      isBusy: () => _isSaving || _isPickingPhotos || _draftLoading || _isTranscribingNow ||
        _recorder.state == RecorderState.finishing || _recorder.state == RecorderState.requestingPermission,
      onSaveDraft: _saveDraft, onDiscard: _discardDraft,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.9),
          child: AbsorbPointer(absorbing: _draftLoading, child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Row(children: [
                  Expanded(child: Text(l10n.quickAddTitle, style: Theme.of(context).textTheme.titleLarge)),
                  IconButton(tooltip: l10n.commonCancel, icon: const Icon(Icons.close), onPressed: () async {
                    if (await confirmDiscardIfNeeded() && mounted) Navigator.pop(this.context);
                  }),
                ]),
                if (_draftRestored) Text(l10n.storyDraftRestored),
                if (_draftLoading) const LinearProgressIndicator(),
                const SizedBox(height: 16),
                _buildRecordButton(l10n),
                const SizedBox(height: 12),
                _buildTextField(l10n),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _isPickingPhotos || _isSaving ? null : _pickPhotos,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  label: Text(l10n.storyAddPhotos),
                ),
                Text(l10n.storyPhotosLocal,
                    style: Theme.of(context).textTheme.bodySmall),
                if (_photos.isNotEmpty)
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final file in _photos) StoryPhoto(file: file),
                  ]),
                const SizedBox(height: 20),
                Text(l10n.quickAddPersonsLabel, style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 8),
                TranscriptPeoplePicker(controller: _peoplePicker,
                    selectedNames: _selectedPersons.map((p) => normalizedPersonName(p.displayName)).toSet()),
                _buildPersonsPicker(l10n),
                const SizedBox(height: 20),
                Text(l10n.quickAddWhenLabel, style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 8),
                _buildDateChoices(l10n),
                const SizedBox(height: 20),
                _buildPlaceField(l10n),
                const SizedBox(height: 16),
                TextField(
                  controller: _titleController,
                  decoration: InputDecoration(
                    labelText: l10n.quickAddTitleLabel,
                    hintText: l10n.quickAddTitleHint,
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _canSave ? _save : null,
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                  child: _isSaving
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(l10n.quickAddSave),
                ),
              ],
            ),
          )),
        ),
      ),
    );
  }

  Widget _buildRecordButton(AppLocalizations l10n) {
    final isRecording = _recorder.state == RecorderState.recording;
    final isBusy = _recorder.state == RecorderState.requestingPermission ||
        _recorder.state == RecorderState.finishing || _isTranscribingNow;

    return Column(
      children: [
        Center(
          child: Semantics(
            label: isRecording ? l10n.quickAddStopRecording : _recorder.canRetryStop ? l10n.storyRetryFinish : l10n.quickAddStartRecording,
            button: true,
            child: GestureDetector(
              onTap: isBusy ? null : _toggleRecording,
              child: Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isRecording
                      ? Colors.red
                      : Theme.of(context).colorScheme.primary,
                ),
                child: Icon(
                  isRecording ? Icons.stop : _recorder.canRetryStop ? Icons.refresh : Icons.mic,
                  color: Colors.white,
                  size: 40,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (_recorder.state == RecorderState.failed && _recorder.failure != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              _recorder.canRetryStop ? l10n.storyRecordingStopFailed : messageForMicFailure(l10n, _recorder.failure!.reason),
              style: const TextStyle(color: Colors.red),
              textAlign: TextAlign.center,
            ),
          ),
        if (isRecording) ...[
          Text(_formatElapsed(_recorder.elapsed)),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _recorder.inputLevel.clamp(0.0, 1.0),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 4),
          if (!_recorder.isTranscribing) Text(
            messageForTranscriptionReason(l10n, _recorder.liveTranscriptionReason),
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
        if (_recorder.isTranscribing ||
            _recorder.state == RecorderState.finishing || _isTranscribingNow)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Flexible(child: Text(l10n.quickAddTranscribing)),
              ],
            ),
          ),
        if (_recorder.isAnonymousRecording && _pendingRecording == null)
          Text(l10n.recordingAnonymousAllowance,
              style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
        if (!isRecording && _recorder.liveTranscriptionReason == LiveTranscriptionReason.anonymousLimit)
          Text(l10n.liveTranscriptionAnonymousLimit),
        if (!isRecording && _pendingRecording != null)
          Text(l10n.recordingAttachedWithDuration(_formatElapsed(
              Duration(milliseconds: _pendingRecording!.durationMs ?? 0)))),
        if (_recorder.lastStopResult?.stopReason == StopReason.anonymousLimit)
          Text(l10n.recordingAnonymousStopped, textAlign: TextAlign.center),
        if (!isRecording &&
            _pendingRecording != null &&
            (_textController.text.trim().isEmpty ||
                _hasFailedTranscription))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: TextButton(
              onPressed: _isTranscribingNow ? null : _transcribeNow,
              child: Text(l10n.quickAddTranscribeNow),
            ),
          ),
      ],
    );
  }

  String _formatElapsed(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    return d.inHours > 0
        ? '${two(d.inHours)}:${two(minutes)}:${two(seconds)}'
        : '${two(minutes)}:${two(seconds)}';
  }

  Widget _buildTextField(AppLocalizations l10n) {
    return TextField(
      controller: _textController,
      minLines: 3,
      maxLines: 8,
      decoration: InputDecoration(
        labelText: l10n.quickAddTextFieldLabel,
        hintText: l10n.quickAddTextFieldHint,
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _buildPersonsPicker(AppLocalizations l10n) {
    // Keep the user's original capitalisation for display/creation
    // ("Grandma Rose", not "grandma rose"); only the lowercased copy is
    // used for case-insensitive matching against existing persons.
    final rawQuery = _personSearchController.text.trim();
    final query = rawQuery.toLowerCase();
    final selectedIds = _selectedPersons.map((p) => p.existing?.id).toSet();
    final suggestions = query.isEmpty
        ? const <Person>[]
        : _allPersons
            .where((p) => !selectedIds.contains(p.id) && [p.name, ...p.aliases].any((name) => name.toLowerCase().contains(query)))
            .take(5)
            .toList();
    final exactMatch =
        _allPersons.any((p) => [p.name, ...p.aliases].any((name) => name.toLowerCase() == query)) || query.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_selectedPersons.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: _selectedPersons
                .map((pick) => Chip(
                      avatar: pick.existing == null
                          ? const Icon(Icons.person_add_alt_1, size: 18)
                          : null,
                      label: Text(pick.displayName),
                      onDeleted: () => _removePerson(pick),
                    ))
                .toList(),
          ),
        const SizedBox(height: 8),
        TextField(
          controller: _personSearchController,
          decoration: InputDecoration(
            hintText: l10n.quickAddPersonSearchHint,
            prefixIcon: const Icon(Icons.person_search),
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (value) {
            if (!exactMatch) _addNewPersonName(value);
          },
        ),
        if (suggestions.isNotEmpty || (query.isNotEmpty && !exactMatch))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final person in suggestions)
                  ActionChip(
                    label: Text(person.name),
                    onPressed: () => _selectExistingPerson(person),
                  ),
                if (query.isNotEmpty && !exactMatch)
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 18),
                    label: Text(l10n.quickAddAddNewPerson(rawQuery)),
                    onPressed: () => _addNewPersonName(rawQuery),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildDateChoices(AppLocalizations l10n) {
    final locale = Localizations.localeOf(context).toString();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            ChoiceChip(
              label: Text(l10n.quickAddToday),
              selected: _datePrecision == DatePrecision.day &&
                  _isSameDay(_date, DateTime.now()),
              onSelected: (_) => _pickToday(),
            ),
            ChoiceChip(
              label: Text(l10n.quickAddAYear),
              selected: _datePrecision == DatePrecision.year,
              onSelected: (_) => _pickDate(DatePrecision.year),
            ),
            ChoiceChip(
              label: Text(l10n.quickAddMonthAndYear),
              selected: _datePrecision == DatePrecision.month,
              onSelected: (_) => _pickDate(DatePrecision.month),
            ),
            ChoiceChip(
              label: Text(l10n.quickAddExactDate),
              selected: _datePrecision == DatePrecision.day &&
                  !_isSameDay(_date, DateTime.now()),
              onSelected: (_) => _pickDate(DatePrecision.day),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(formatDateWithPrecision(_date, _datePrecision, locale),
            style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Widget _buildPlaceField(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _placeNameController,
          enabled: _useExistingPlace == null,
          decoration: InputDecoration(
            labelText: l10n.quickAddPlaceNameLabel,
            hintText: _suggestedPosition == widget.position.value
                ? _suggestedPlaceName ?? l10n.quickAddPlaceNameHint
                : l10n.quickAddPlaceNameHint,
            suffixIcon: _useExistingPlace != null
                ? IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: _clearExistingPlaceChoice,
                    tooltip: l10n.quickAddUseDifferentPlace,
                  )
                : null,
          ),
        ),
        if (_nearbyPlace != null && _useExistingPlace == null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: ActionChip(
              avatar: const Icon(Icons.place, size: 18),
              label: Text(l10n.quickAddUsingNearbyPlace(_nearbyPlace!.name),
                  maxLines: 3, softWrap: true),
              onPressed: _useNearbyPlace,
            ),
          ),
        TextButton.icon(onPressed: _changePosition, icon: const Icon(Icons.edit_location_alt_outlined),
          label: Text(l10n.quickAddChangePosition)),
        if (_lookupFailed)
          TextButton(onPressed: _loadLookups, child: Text(l10n.commonRetry)),
        if (!_loadedLookups && !_lookupFailed)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }
}
