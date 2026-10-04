import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../l10n/gen/app_localizations.dart';
import '../models/models.dart';
import '../relationships/relationship_text.dart';
import '../services/auth_service.dart';
import '../services/database_service.dart';
import '../services/recording_file_store.dart';
import '../services/training_sample_client.dart';

/// One explicit reporting action per recording; opening or cancelling sends nothing.
class TrainingSampleButton extends StatelessWidget {
  final Event event;
  final AttachedFile file;
  final RecordingFileStore store;

  const TrainingSampleButton(
      {super.key,
      required this.event,
      required this.file,
      required this.store});

  @override
  Widget build(BuildContext context) => TextButton.icon(
        key: ValueKey('training-report-${file.id}'),
        icon: const Icon(Icons.feedback_outlined),
        label: Text(AppLocalizations.of(context).trainingReport),
        onPressed: () {
          final auth = context.read<AuthService>();
          showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) => TrainingSampleDialog(
                  event: event,
                  file: file,
                  store: store,
                  db: context.read<DatabaseService>(),
                  client: TrainingSampleClient(
                      baseUrl: auth.baseUrl, getToken: () => auth.token),
                  closeClient: true));
        },
      );
}

class TrainingSampleDialog extends StatefulWidget {
  final Event event;
  final AttachedFile file;
  final RecordingFileStore store;
  final DatabaseService db;
  final TrainingSampleClient client;
  final String? language;
  final bool closeClient;

  const TrainingSampleDialog(
      {super.key,
      required this.event,
      required this.file,
      required this.store,
      required this.db,
      required this.client,
      this.language,
      this.closeClient = false});

  @override
  State<TrainingSampleDialog> createState() => _TrainingSampleDialogState();
}

class _TrainingSampleDialogState extends State<TrainingSampleDialog> {
  final _sampleId = const Uuid().v4();
  final _correction = TextEditingController();
  TrainingSampleSnapshot? _snapshot;
  TrainingSampleError? _error;
  bool _includeAudio = true;
  bool _consent = false;
  bool _sending = false;
  String? _receipt;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final people = await widget.db.getPersons();
      final connections =
          await widget.db.getConnectionsForEvent(widget.event.id);
      if (!mounted) return;
      setState(() {
        _snapshot =
            TrainingSampleSnapshot.fromStory(widget.event, people, connections);
      });
    } catch (_) {
      if (mounted) setState(() => _error = TrainingSampleError.other);
    }
  }

  @override
  void dispose() {
    _correction.dispose();
    if (widget.closeClient) widget.client.close();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_sending || !_consent || _snapshot == null) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final id = await widget.client.submit(
          sampleId: _sampleId,
          consent: _consent,
          snapshot: _snapshot!,
          correction: _correction.text,
          language: widget.language,
          store: _includeAudio ? widget.store : null,
          recordingId: _includeAudio ? widget.file.id : null);
      if (mounted) setState(() => _receipt = id);
    } on TrainingSampleException catch (e) {
      if (mounted) setState(() => _error = e.kind);
    } catch (_) {
      if (mounted) setState(() => _error = TrainingSampleError.other);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final snapshot = _snapshot;
    return PopScope(
        canPop: !_sending,
        child: AlertDialog(
          title: Text(l10n.trainingReport),
          content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                  child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_receipt != null)
                    SelectableText(l10n.trainingReceipt(_receipt!))
                  else ...[
                    Text(l10n.trainingScopeHelp),
                    const SizedBox(height: 12),
                    Text(l10n.trainingRecording(widget.file.fileName)),
                    const SizedBox(height: 12),
                    Text(l10n.trainingSharedText,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    SelectableText(widget.event.description ?? ''),
                    const SizedBox(height: 12),
                    Text(l10n.trainingSnapshot,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    if (snapshot == null && _error == null)
                      const LinearProgressIndicator(),
                    if (snapshot != null) ...[
                      for (final person in snapshot.people)
                        Text([
                          person.name,
                          if (person.company != null) person.company!,
                          ...person.facts
                        ].join('\n')),
                      for (final connection in snapshot.connections)
                        Text(RelationshipText.sentenceForRaw(
                            l10n,
                            connection.person1Name,
                            connection.person2Name,
                            connection.type)),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                        key: const Key('training-correction'),
                        controller: _correction,
                        enabled: !_sending,
                        maxLength: 4000,
                        minLines: 2,
                        maxLines: 5,
                        decoration: InputDecoration(
                            labelText: l10n.trainingCorrection)),
                    CheckboxListTile(
                        key: const Key('training-audio'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(l10n.trainingAudio),
                        value: _includeAudio,
                        onChanged: _sending
                            ? null
                            : (value) =>
                                setState(() => _includeAudio = value!)),
                    CheckboxListTile(
                        key: const Key('training-consent'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(l10n.trainingConsent),
                        value: _consent,
                        onChanged: _sending
                            ? null
                            : (value) => setState(() => _consent = value!)),
                    if (_error != null)
                      Text(l10n.trainingError(_error!.name),
                          key: const Key('training-error'),
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                    if (_sending) const LinearProgressIndicator(),
                  ],
                ],
              ))),
          actions: [
            TextButton(
                onPressed: _sending ? null : () => Navigator.pop(context),
                child: Text(
                    _receipt != null ? l10n.commonClose : l10n.commonCancel)),
            if (_receipt == null && snapshot == null && _error != null)
              TextButton(
                  onPressed: () {
                    setState(() => _error = null);
                    _load();
                  },
                  child: Text(l10n.commonRetry)),
            if (_receipt == null && snapshot != null)
              FilledButton(
                  key: const Key('training-submit'),
                  onPressed: _consent && !_sending ? _submit : null,
                  child: Text(l10n.trainingSubmit)),
          ],
        ));
  }
}
