import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../services/app_settings_service.dart';
import '../../services/audio_capture.dart';
import '../../services/auth_service.dart';
import '../../services/database_service.dart';
import '../../services/record_package_audio_capture.dart';
import '../../services/recorder_controller.dart';
import '../../services/recording_file_store.dart';
import '../../services/transcription_client.dart';
import '../map/nearby_place.dart';

/// User-facing text for the quick add sheet, kept in one place so a later
/// localisation pass doesn't have to hunt through the widget's logic.
class _Strings {
  static const sheetTitle = 'New story';
  static const startRecording = 'Start recording';
  static const stopRecording = 'Stop recording';
  static const textFieldLabel = 'What happened here?';
  static const textFieldHint = 'Type, or record and it fills in as you talk';
  static const transcribeNow = 'Transcribe now';
  static const transcribing = 'Transcribing…';
  static const personsLabel = 'Who was there?';
  static const personSearchHint = 'Type a name';
  static const addAsNewPerson = 'Add ';
  static const whenLabel = 'When';
  static const today = 'Today';
  static const aYear = 'A year';
  static const monthAndYear = 'Month and year';
  static const exactDate = 'Exact date';
  static const placeNameLabel = 'Place name (optional)';
  static const placeNameHint = 'Leave blank for a default name';
  static const titleLabel = 'Title (optional)';
  static const titleHint = 'Leave blank to use the start of the text';
  static const save = 'Save story';
  static const cancel = 'Cancel';
  static const ok = 'OK';
  static const which = 'Which';
  static const discardTitle = 'Discard this story?';
  static const discardBody = 'What you\'ve entered so far will be lost.';
  static const discardBodyWithRecording =
      'The recording will be kept (you can attach it to a story later); everything else will be lost.';
  static const keepEditing = 'Keep editing';
  static const discard = 'Discard';
  static const needsTextOrRecording = 'Add some text or record something first.';

  static String usingNearbyPlace(String name) => 'Use "$name" (nearby)';

  static String messageForTranscriptionReason(LiveTranscriptionReason reason) {
    switch (reason) {
      case LiveTranscriptionReason.notStarted:
        return 'Recording…';
      case LiveTranscriptionReason.working:
        return 'Live transcription is working.';
      case LiveTranscriptionReason.offline:
        return 'Offline - recording without live transcription.';
      case LiveTranscriptionReason.notSignedIn:
        return 'Sign in for live transcription - recording continues without it.';
      case LiveTranscriptionReason.notConfigured:
        return 'Live transcription isn\'t available right now.';
      case LiveTranscriptionReason.failing:
        return 'Live transcription is having trouble - recording continues.';
    }
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
  final ValueListenable<LatLng> position;

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
    required ValueListenable<LatLng> position,
    Place? initialPlace,
  }) {
    return showModalBottomSheet<QuickAddResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
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
  List<Person> _allPersons = [];
  List<Place> _allPlaces = [];
  Place? _nearbyPlace;
  Place? _useExistingPlace;

  DateTime _date = DateTime.now();
  DatePrecision _datePrecision = DatePrecision.day;

  late final RecorderController _recorder;
  bool _ownsRecorder = false;
  AttachedFile? _pendingRecording;
  String _liveTextAlreadyShown = '';
  bool _isSaving = false;
  bool _isTranscribingNow = false;
  bool _loadedLookups = false;

  @override
  void initState() {
    super.initState();
    if (widget.recorderController != null) {
      _recorder = widget.recorderController!;
    } else {
      _recorder = _buildDefaultRecorderController(context);
      _ownsRecorder = true;
    }
    _recorder.addListener(_onRecorderChanged);
    if (widget.initialPlace != null) {
      _useExistingPlace = widget.initialPlace;
      _placeNameController.text = widget.initialPlace!.name;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadLookups());
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
    );
  }

  Future<void> _loadLookups() async {
    final db = context.read<DatabaseService>();
    final persons = await db.getPersons();
    final places = await db.getPlaces();
    if (!mounted) return;
    setState(() {
      _allPersons = persons;
      _allPlaces = places;
      _loadedLookups = true;
      _updateNearbyPlace(widget.position.value);
    });
  }

  void _updateNearbyPlace(LatLng point) {
    _nearbyPlace = findNearbyPlace(_allPlaces, point);
    // Don't second-guess a place the sheet was explicitly opened for (e.g.
    // the place sheet's "Add story here"); only clear an existing-place
    // choice the user made themselves via the nearby-place proposal.
    if (widget.initialPlace == null && _nearbyPlace == null && _useExistingPlace != null) {
      _useExistingPlace = null;
    }
  }

  void _onRecorderChanged() {
    if (!mounted) return;
    if (_recorder.state == RecorderState.recording) {
      _appendLiveTranscriptDelta();
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
    _liveTextAlreadyShown = live;
    if (delta.isEmpty) return;

    final controller = _textController;
    final oldSelection = controller.selection;
    final newText = controller.text.isEmpty ? delta : controller.text + delta;
    final newSelection =
        oldSelection.isValid ? oldSelection : TextSelection.collapsed(offset: newText.length);
    controller.value = TextEditingValue(text: newText, selection: newSelection);
  }

  Future<void> _toggleRecording() async {
    if (_recorder.state == RecorderState.recording) {
      final result = await _recorder.stop();
      _pendingRecording = result.attachedFile;
      if (mounted && result.failedSegments.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                '${result.failedSegments.length} part(s) could not be transcribed live. The audio was kept.'),
          ),
        );
      }
      setState(() {});
      return;
    }
    await _recorder.start();
  }

  Future<void> _transcribeNow() async {
    final recordingId = _pendingRecording?.id;
    if (recordingId == null || _isTranscribingNow) return;
    setState(() => _isTranscribingNow = true);
    final result = await _recorder.transcribeStoredRecording(recordingId);
    if (!mounted) return;
    setState(() {
      _isTranscribingNow = false;
      if (result.transcript.isNotEmpty) {
        final sep = _textController.text.trim().isEmpty ? '' : ' ';
        _textController.text = '${_textController.text}$sep${result.transcript}'.trim();
      }
    });
  }

  void _selectExistingPerson(Person person) {
    setState(() {
      _selectedPersons.add(PersonPick.existing(person));
      _personSearchController.clear();
    });
  }

  void _addNewPersonName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    setState(() {
      _selectedPersons.add(PersonPick.newName(trimmed));
      _personSearchController.clear();
    });
  }

  void _removePerson(PersonPick pick) {
    setState(() => _selectedPersons.remove(pick));
  }

  void _useNearbyPlace() {
    setState(() {
      _useExistingPlace = _nearbyPlace;
      _placeNameController.text = _nearbyPlace!.name;
    });
  }

  void _clearExistingPlaceChoice() {
    setState(() {
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

  Future<void> _pickYear() async {
    final controller = TextEditingController(text: _date.year.toString());
    final year = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('${_Strings.which} year?'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext), child: const Text(_Strings.cancel)),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, int.tryParse(controller.text.trim())),
            child: const Text(_Strings.ok),
          ),
        ],
      ),
    );
    if (year != null && mounted) {
      setState(() {
        _date = DateTime(year);
        _datePrecision = DatePrecision.year;
      });
    }
  }

  Future<void> _pickMonthAndYear() async {
    var month = _date.month;
    var year = _date.year;
    final result = await showDialog<DateTime>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('${_Strings.which} month?'),
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButton<int>(
                value: month,
                items: [
                  for (var m = 1; m <= 12; m++)
                    DropdownMenuItem(value: m, child: Text(DateFormat.MMMM().format(DateTime(2000, m)))),
                ],
                onChanged: (v) => setDialogState(() => month = v ?? month),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 90,
                child: TextField(
                  keyboardType: TextInputType.number,
                  controller: TextEditingController(text: year.toString()),
                  onChanged: (v) => year = int.tryParse(v) ?? year,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext), child: const Text(_Strings.cancel)),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, DateTime(year, month)),
              child: const Text(_Strings.ok),
            ),
          ],
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _date = result;
        _datePrecision = DatePrecision.month;
      });
    }
  }

  Future<void> _pickExactDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
    );
    if (picked != null && mounted) {
      setState(() {
        _date = picked;
        _datePrecision = DatePrecision.day;
      });
    }
  }

  bool get _hasUnsavedContent =>
      _textController.text.trim().isNotEmpty ||
      _pendingRecording != null ||
      _recorder.state == RecorderState.recording ||
      _selectedPersons.isNotEmpty ||
      _placeNameController.text.trim().isNotEmpty ||
      _titleController.text.trim().isNotEmpty;

  /// Returns true if it's safe to close the sheet now (nothing to lose, or
  /// the user confirmed discarding). A recording in progress is stopped
  /// first so its audio is finalized and durably kept - never silently
  /// dropped - and surfaces afterwards as a recording not attached to any
  /// story (see the map's recovered-recordings banner).
  Future<bool> confirmDiscardIfNeeded() async {
    if (!_hasUnsavedContent) return true;

    if (_recorder.state == RecorderState.recording) {
      final result = await _recorder.stop();
      _pendingRecording = result.attachedFile;
    }
    if (!mounted) return true;

    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text(_Strings.discardTitle),
        content: Text(_pendingRecording != null
            ? _Strings.discardBodyWithRecording
            : _Strings.discardBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text(_Strings.keepEditing),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text(_Strings.discard, style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  String _deriveTitle(String text, String placeName) {
    final explicit = _titleController.text.trim();
    if (explicit.isNotEmpty) return explicit;

    final trimmedText = text.trim();
    if (trimmedText.isNotEmpty) {
      final words = trimmedText.split(RegExp(r'\s+'));
      final firstFew = words.take(8).join(' ');
      return firstFew.length < trimmedText.length ? '$firstFew…' : firstFew;
    }
    if (placeName.trim().isNotEmpty) return placeName.trim();
    return 'Story on ${DateFormat.yMMMd().format(_date)}';
  }

  Future<void> _save() async {
    final text = _textController.text.trim();
    if (text.isEmpty && _pendingRecording == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text(_Strings.needsTextOrRecording)));
      return;
    }

    setState(() => _isSaving = true);
    final db = context.read<DatabaseService>();
    final position = widget.position.value;

    Place place;
    if (_useExistingPlace != null) {
      place = _useExistingPlace!;
    } else {
      final name = _placeNameController.text.trim().isNotEmpty
          ? _placeNameController.text.trim()
          : defaultPlaceName(position);
      place = Place(name: name, latitude: position.latitude, longitude: position.longitude);
      await db.savePlace(place);
    }

    final participantIds = <String>[];
    for (final pick in _selectedPersons) {
      if (pick.existing != null) {
        participantIds.add(pick.existing!.id);
      } else {
        final person = Person(name: pick.newName!);
        await db.savePerson(person);
        participantIds.add(person.id);
      }
    }

    final files = <AttachedFile>[if (_pendingRecording != null) _pendingRecording!];
    final event = Event(
      title: _deriveTitle(text, place.name),
      description: text.isEmpty ? null : text,
      dateTime: _date,
      datePrecision: _datePrecision,
      placeId: place.id,
      participantIds: participantIds,
      files: files,
    );
    await db.saveEvent(event);

    final pendingId = _pendingRecording?.id;
    if (pendingId != null) {
      final recording = await db.getLocalRecording(pendingId);
      if (recording != null) {
        await db.saveLocalRecording(recording.copyWith(eventId: event.id));
      }
    }

    if (!mounted) return;
    Navigator.pop(context, QuickAddResult(event: event, place: place));
  }

  @override
  void dispose() {
    _recorder.removeListener(_onRecorderChanged);
    if (_ownsRecorder) {
      _recorder.dispose();
    }
    _textController.dispose();
    _placeNameController.dispose();
    _titleController.dispose();
    _personSearchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (await confirmDiscardIfNeeded() && mounted) {
          Navigator.pop(context);
        }
      },
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.9),
          child: SingleChildScrollView(
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
                Text(_Strings.sheetTitle, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 16),
                _buildRecordButton(),
                const SizedBox(height: 12),
                _buildTextField(),
                const SizedBox(height: 20),
                Text(_Strings.personsLabel, style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 8),
                _buildPersonsPicker(),
                const SizedBox(height: 20),
                Text(_Strings.whenLabel, style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 8),
                _buildDateChoices(),
                const SizedBox(height: 20),
                _buildPlaceField(),
                const SizedBox(height: 16),
                TextField(
                  controller: _titleController,
                  decoration: const InputDecoration(
                    labelText: _Strings.titleLabel,
                    hintText: _Strings.titleHint,
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _isSaving ? null : _save,
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                  child: _isSaving
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text(_Strings.save),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRecordButton() {
    final isRecording = _recorder.state == RecorderState.recording;
    final isBusy = _recorder.state == RecorderState.requestingPermission ||
        _recorder.state == RecorderState.finishing;

    return Column(
      children: [
        Center(
          child: Semantics(
            label: isRecording ? _Strings.stopRecording : _Strings.startRecording,
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
                  isRecording ? Icons.stop : Icons.mic,
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
              _messageForFailure(_recorder.failure!.reason),
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
          Text(
            _Strings.messageForTranscriptionReason(_recorder.liveTranscriptionReason),
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
        if (!isRecording && _pendingRecording != null && _textController.text.trim().isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: TextButton(
              onPressed: _isTranscribingNow ? null : _transcribeNow,
              child: Text(_isTranscribingNow ? _Strings.transcribing : _Strings.transcribeNow),
            ),
          ),
      ],
    );
  }

  String _messageForFailure(AudioCaptureFailureReason reason) {
    switch (reason) {
      case AudioCaptureFailureReason.permissionDenied:
        return 'Microphone permission was denied.';
      case AudioCaptureFailureReason.noMicrophone:
        return 'No microphone is available on this device.';
      case AudioCaptureFailureReason.other:
        return 'Could not start recording.';
    }
  }

  String _formatElapsed(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    return d.inHours > 0
        ? '${two(d.inHours)}:${two(minutes)}:${two(seconds)}'
        : '${two(minutes)}:${two(seconds)}';
  }

  Widget _buildTextField() {
    return TextField(
      controller: _textController,
      minLines: 3,
      maxLines: 8,
      decoration: const InputDecoration(
        labelText: _Strings.textFieldLabel,
        hintText: _Strings.textFieldHint,
        border: OutlineInputBorder(),
      ),
    );
  }

  Widget _buildPersonsPicker() {
    // Keep the user's original capitalisation for display/creation
    // ("Grandma Rose", not "grandma rose"); only the lowercased copy is
    // used for case-insensitive matching against existing persons.
    final rawQuery = _personSearchController.text.trim();
    final query = rawQuery.toLowerCase();
    final selectedIds = _selectedPersons.map((p) => p.existing?.id).toSet();
    final suggestions = query.isEmpty
        ? const <Person>[]
        : _allPersons
            .where((p) => !selectedIds.contains(p.id) && p.name.toLowerCase().contains(query))
            .take(5)
            .toList();
    final exactMatch =
        _allPersons.any((p) => p.name.toLowerCase() == query) || query.isEmpty;

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
          decoration: const InputDecoration(
            hintText: _Strings.personSearchHint,
            prefixIcon: Icon(Icons.person_search),
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
                    label: Text('${_Strings.addAsNewPerson}"$rawQuery"'),
                    onPressed: () => _addNewPersonName(rawQuery),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildDateChoices() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            ChoiceChip(
              label: const Text(_Strings.today),
              selected: _datePrecision == DatePrecision.day &&
                  _isSameDay(_date, DateTime.now()),
              onSelected: (_) => _pickToday(),
            ),
            ChoiceChip(
              label: const Text(_Strings.aYear),
              selected: _datePrecision == DatePrecision.year,
              onSelected: (_) => _pickYear(),
            ),
            ChoiceChip(
              label: const Text(_Strings.monthAndYear),
              selected: _datePrecision == DatePrecision.month,
              onSelected: (_) => _pickMonthAndYear(),
            ),
            ChoiceChip(
              label: const Text(_Strings.exactDate),
              selected: _datePrecision == DatePrecision.day &&
                  !_isSameDay(_date, DateTime.now()),
              onSelected: (_) => _pickExactDate(),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(formatDateWithPrecision(_date, _datePrecision),
            style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Widget _buildPlaceField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _placeNameController,
          enabled: _useExistingPlace == null,
          decoration: InputDecoration(
            labelText: _Strings.placeNameLabel,
            hintText: _Strings.placeNameHint,
            suffixIcon: _useExistingPlace != null
                ? IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: _clearExistingPlaceChoice,
                    tooltip: 'Use a different place',
                  )
                : null,
          ),
        ),
        if (_nearbyPlace != null && _useExistingPlace == null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: ActionChip(
              avatar: const Icon(Icons.place, size: 18),
              label: Text(_Strings.usingNearbyPlace(_nearbyPlace!.name)),
              onPressed: _useNearbyPlace,
            ),
          ),
        if (!_loadedLookups)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }
}
