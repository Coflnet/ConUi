import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../models/models.dart';
import '../../services/app_settings_service.dart';
import '../../services/auth_service.dart';
import '../../services/database_service.dart';
import '../../services/story_photo_service.dart';
import '../../widgets/story_photo.dart';
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

  const AddEventScreen({super.key, this.existingEvent, this.recorderController});

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
  String? _placeId;
  bool _isSaving = false;
  bool _isPickingPhotos = false;
  late final Event _draftEvent;
  final List<AttachedFile> _photos = [];

  late final RecorderController _recorder;
  bool _ownsRecorder = false;
  AttachedFile? _pendingRecording;
  String? _descriptionBeforeRecording;

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
      _endDateTime = e.endDateTime;
      _participantIds = List.from(e.participantIds);
      _placeId = e.placeId;
    }

    if (widget.recorderController != null) {
      _recorder = widget.recorderController!;
    } else {
      _recorder = _buildDefaultRecorderController(context);
      _ownsRecorder = true;
    }
    _recorder.addListener(_onRecorderChanged);
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

  void _onRecorderChanged() {
    if (!mounted) return;
    // While recording, the live transcript flows straight into the
    // description field so the user sees it forming as they talk.
    if (_recorder.state == RecorderState.recording) {
      final live = _recorder.liveTranscript;
      if (live.isNotEmpty) {
        _descriptionController.text = live;
      }
    }
    setState(() {});
  }

  @override
  void dispose() {
    _recorder.removeListener(_onRecorderChanged);
    if (_ownsRecorder) {
      _recorder.dispose();
    }
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _toggleRecording() async {
    if (_recorder.state == RecorderState.recording) {
      final result = await _recorder.stop();
      _pendingRecording = result.attachedFile;
      if (result.transcript.isNotEmpty) {
        _descriptionController.text = result.transcript;
      } else if (_descriptionBeforeRecording != null) {
        _descriptionController.text = _descriptionBeforeRecording!;
      }
      if (mounted && result.failedSegments.isNotEmpty) {
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.recordingPartsFailedLive(result.failedSegments.length))),
        );
      }
      return;
    }

    _descriptionBeforeRecording = _descriptionController.text;
    await _recorder.start();
  }

  Future<void> _pickPhotos() async {
    setState(() => _isPickingPhotos = true);
    try {
      final photos = await StoryPhotoService(context.read<DatabaseService>())
          .pickPhotos(_draftEvent.id);
      if (mounted) setState(() => _photos.addAll(photos));
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text(AppLocalizations.of(context).storyPhotoImportFailed)),
        );
    } finally {
      if (mounted) setState(() => _isPickingPhotos = false);
    }
  }

  Future<void> _selectDateTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _dateTime,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date == null) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_dateTime),
    );
    if (time == null) return;

    setState(() {
      _dateTime =
          DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  bool get _canSave =>
      !_isSaving &&
      !_isPickingPhotos &&
      (_recorder.state == RecorderState.idle || _recorder.state == RecorderState.failed);

  Future<void> _save() async {
    if (!_canSave) return;
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSaving = true);

    final db = context.read<DatabaseService>();
    final newFiles = <AttachedFile>[
      ...(widget.existingEvent?.files ?? const []),
      if (_pendingRecording != null) _pendingRecording!,
      ..._photos,
    ];
    final event = widget.existingEvent != null
        ? widget.existingEvent!.copyWith(
            title: _titleController.text.trim(),
            description: _descriptionController.text.trim().isEmpty
                ? null
                : _descriptionController.text.trim(),
            type: _type,
            dateTime: _dateTime,
            endDateTime: _endDateTime,
            participantIds: _participantIds,
            placeId: _placeId,
            files: newFiles,
          )
        : Event(
            id: _draftEvent.id,
            title: _titleController.text.trim(),
            description: _descriptionController.text.trim().isEmpty
                ? null
                : _descriptionController.text.trim(),
            type: _type,
            dateTime: _dateTime,
            endDateTime: _endDateTime,
            participantIds: _participantIds,
            placeId: _placeId,
            files: newFiles,
          );

    await db.saveEvent(event);

    final pending = _pendingRecording;
    if (pending != null) {
      final recording = await db.getLocalRecording(pending.id);
      if (recording != null) {
        await db.saveLocalRecording(recording.copyWith(eventId: event.id));
      }
    }

    if (mounted) {
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
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toString();
    return Scaffold(
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
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _titleController,
              decoration: InputDecoration(
                  labelText: l10n.addEventTitleFieldLabel, prefixIcon: const Icon(Icons.title)),
              validator: (v) =>
                  v == null || v.trim().isEmpty ? l10n.addEventTitleRequired : null,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<EventType>(
              value: _type,
              decoration: InputDecoration(
                  labelText: l10n.addEventTypeLabel, prefixIcon: const Icon(Icons.category)),
              items: EventType.values
                  .map((t) => DropdownMenuItem(value: t, child: Text(eventTypeLabel(l10n, t))))
                  .toList(),
              onChanged: (v) => setState(() => _type = v ?? EventType.other),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.schedule),
              title: Text(DateFormat.yMMMd(locale).add_jm().format(_dateTime)),
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
            _buildRecordingCard(l10n),
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
            TextFormField(
              controller: _descriptionController,
              decoration: InputDecoration(
                  labelText: l10n.addEventDescriptionLabel, prefixIcon: const Icon(Icons.note)),
              maxLines: 3,
            ),
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                leading: const Icon(Icons.people),
                title: Text(_participantIds.isEmpty
                    ? l10n.addEventAddParticipants
                    : l10n.addEventParticipantsCount(_participantIds.length)),
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
    );
  }

  Widget _buildRecordingCard(AppLocalizations l10n) {
    final state = _recorder.state;
    final isRecording = state == RecorderState.recording;
    final isBusy = state == RecorderState.requestingPermission ||
        state == RecorderState.finishing;

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
                    isRecording ? Icons.stop_circle : Icons.mic,
                    color: isRecording ? Colors.red : null,
                  ),
                  iconSize: 36,
                  onPressed: isBusy ? null : _toggleRecording,
                ),
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
                  messageForMicFailure(l10n, _recorder.failure!.reason),
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            if (isRecording)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  messageForTranscriptionReason(l10n, _recorder.liveTranscriptionReason),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
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
    if (date == null) return;

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

  void _selectParticipants() async {
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
                      value: _participantIds.contains(p.id),
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            _participantIds.add(p.id);
                          } else {
                            _participantIds.remove(p.id);
                          }
                        });
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
  }

  void _selectPlace() async {
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
  }

  /// The "pick on map" action: opens the same [LocationPickerScreen] the
  /// quick add sheet and place sheet use, then either proposes an existing
  /// place within 50m (see [findNearbyPlace]) or creates a new one with a
  /// sensible default name at that spot.
  Future<void> _pickPlaceOnMap(DatabaseService db, List<Place> places) async {
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
    final place = Place(
      name: defaultPlaceName(position, AppLocalizations.of(context)),
      latitude: position.latitude,
      longitude: position.longitude,
    );
    await db.savePlace(place);
    if (mounted) setState(() => _placeId = place.id);
  }
}
