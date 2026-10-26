import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';

import '../l10n/gen/app_localizations.dart';
import '../models/models.dart';
import '../services/dia_contribution_client.dart';
import '../services/dia_sentence.dart';
import '../services/dia_region_service.dart';
import '../services/dia_recording_detector.dart';
import '../services/transcription_client.dart';
import '../services/auth_service.dart';
import '../services/app_settings_service.dart';
import '../services/recording_clip.dart';
import '../services/recording_file_store.dart';

Future<void> showDiaCorrection(
  BuildContext context, {
  required AttachedFile file,
  required RecordingFileStore store,
  TextEditingValue? source,
  Future<void> Function(List<RecordingTranscriptSlice>)? onTranscriptDetected,
}) async {
  final auth = context.read<AuthService?>();
  final transcription = auth == null
      ? null
      : TranscriptionClient(baseUrl: auth.baseUrl, getToken: () => auth.token);
  final language =
      context.read<AppSettingsService?>()?.effectiveRecordingLanguage;
  try {
    await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => DiaCorrectionDialog(
            file: file,
            store: store,
            source: source,
            onTranscriptDetected: onTranscriptDetected,
            transcriptionClient: transcription,
            language: language));
  } finally {
    transcription?.close();
  }
}

/// The text selection identifies the sentence; audio retains verified boundaries.
Widget diaCorrectionTextMenu(
  BuildContext context,
  EditableTextState editable, {
  required List<AttachedFile> recordings,
  required RecordingFileStore store,
  Future<void> Function(AttachedFile, List<RecordingTranscriptSlice>)?
      onTranscriptDetected,
}) {
  final source = editable.textEditingValue;
  final matches = recordings
      .where((file) =>
          _sentenceAtSelection(detectDiaSentences(file.transcriptSlices),
              source, file.transcriptSlices) !=
          null)
      .toList();
  final file = matches.length == 1
      ? matches.single
      : recordings.length == 1 && recordings.single.transcriptSlices.isEmpty
          ? recordings.single
          : null;
  return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editable.contextMenuAnchors,
      buttonItems: [
        ...editable.contextMenuButtonItems,
        if (file != null &&
            source.selection.isValid &&
            !source.selection.isCollapsed)
          ContextMenuButtonItem(
              label: AppLocalizations.of(context).diaCorrectWord,
              onPressed: () {
                ContextMenuController.removeAny();
                showDiaCorrection(context,
                    file: file,
                    store: store,
                    source: source,
                    onTranscriptDetected: onTranscriptDetected == null
                        ? null
                        : (slices) => onTranscriptDetected(file, slices));
              }),
      ]);
}

int? _recordingSourceStart(
    List<RecordingTranscriptSlice> slices, String source) {
  final recordingText = slices.map((slice) => slice.text).join(' ');
  if (recordingText.isEmpty) return null;
  final start = source.indexOf(recordingText);
  return start >= 0 && source.indexOf(recordingText, start + 1) < 0
      ? start
      : null;
}

int? _sentenceSourceStart(
    DiaSentence sentence, String source, int? recordingStart) {
  if (recordingStart != null) {
    return recordingStart + sentence.recordingTextStart;
  }
  final start = source.indexOf(sentence.contextText);
  return start >= 0 && source.indexOf(sentence.contextText, start + 1) < 0
      ? start + sentence.textStart
      : null;
}

int? _sentenceAtSelection(List<DiaSentence> sentences, TextEditingValue? source,
    List<RecordingTranscriptSlice> slices) {
  if (source == null || !source.selection.isValid) return null;
  final recordingStart = _recordingSourceStart(slices, source.text);
  int? match;
  for (var index = 0; index < sentences.length; index++) {
    final sentence = sentences[index];
    final start = _sentenceSourceStart(sentence, source.text, recordingStart);
    if (start != null &&
        source.selection.start >= start &&
        source.selection.end <= start + sentence.text.length) {
      if (match != null) {
        return null; // An edited story must not select ambiguous audio.
      }
      match = index;
    }
  }
  return match;
}

class DiaCorrectionButton extends StatelessWidget {
  final AttachedFile file;
  final RecordingFileStore store;
  final TextEditingController? transcriptController;
  final String? transcript;
  final Future<void> Function(List<RecordingTranscriptSlice>)?
      onTranscriptDetected;
  const DiaCorrectionButton(
      {super.key,
      required this.file,
      required this.store,
      this.transcriptController,
      this.transcript,
      this.onTranscriptDetected});

  @override
  Widget build(BuildContext context) => TextButton.icon(
      key: ValueKey('dia-correct-${file.id}'),
      icon: const Icon(Icons.spellcheck),
      label: Text(AppLocalizations.of(context).diaCorrectSentence),
      onPressed: () => showDiaCorrection(context,
          file: file,
          store: store,
          source: transcriptController?.value ??
              (transcript == null ? null : TextEditingValue(text: transcript!)),
          onTranscriptDetected: onTranscriptDetected));
}

class DiaCorrectionDialog extends StatefulWidget {
  final AttachedFile file;
  final RecordingFileStore store;
  final DiaContributionClient? client;
  final TranscriptionClient? transcriptionClient;
  final String? language;
  final TextEditingValue? source;
  final Future<void> Function(List<RecordingTranscriptSlice>)?
      onTranscriptDetected;
  final Future<DiaRegion?> Function()? regionSuggestion;
  const DiaCorrectionDialog(
      {super.key,
      required this.file,
      required this.store,
      this.client,
      this.transcriptionClient,
      this.language,
      this.source,
      this.onTranscriptDetected,
      this.regionSuggestion});

  @override
  State<DiaCorrectionDialog> createState() => _DiaCorrectionDialogState();
}

class _DiaCorrectionDialogState extends State<DiaCorrectionDialog> {
  late final _client = widget.client ?? DiaContributionClient();
  final _correction = TextEditingController();
  final _zip = TextEditingController();
  final _country = TextEditingController();
  AudioPlayer? _player;
  DiaContributionPolicy? _policy;
  DiaContributionReceipt? _receipt;
  String? _error;
  bool _loading = true, _busy = false, _consent = false, _playing = false;
  bool _allowClose = false;
  int? _selected;
  late List<DiaSentence> _sentences;
  late final Future<void> _regionReady;
  bool _detecting = false, _zipEdited = false, _countryEdited = false;
  RangeValues _range = const RangeValues(0, 0);
  double _duration = 0;

  DiaSentence? get _sentence =>
      _selected == null ? null : _sentences[_selected!];
  String get _initialText => _sentence?.text ?? '';
  bool get _dirty => _receipt == null && _correction.text != _initialText;
  int get _startByte => _selected != null
      ? _sentence!.startByte
      : (_range.start * WavFormat.standard.sampleRate).round() *
          WavFormat.standard.blockAlign;
  int get _endByte => _selected != null
      ? _sentence!.endByte
      : (_range.end * WavFormat.standard.sampleRate).round() *
          WavFormat.standard.blockAlign;

  bool get _clipTooLong =>
      _endByte - _startByte >
      DiaContributionClient.maxWavBytes - wavHeaderLength;

  @override
  void initState() {
    super.initState();
    _sentences = detectDiaSentences(widget.file.transcriptSlices);
    if (_sentences.isNotEmpty) {
      _select(_sentenceAtSelection(
              _sentences, widget.source, widget.file.transcriptSlices) ??
          0);
    }
    _load();
    _regionReady = _suggestRegion();
    if (_sentences.isEmpty && widget.transcriptionClient != null) {
      unawaited(_detect());
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    var failure = 'audio';
    try {
      final size = await widget.store.size(widget.file.id);
      failure = 'policy';
      final policy = await _client.fetchPolicy();
      if (!mounted) return;
      setState(() {
        _duration =
            ((size - wavHeaderLength) / WavFormat.standard.bytesPerSecond)
                .clamp(0, double.infinity);
        _range = RangeValues(
            0,
            _duration
                .clamp(0, DiaContributionClient.maxClipSeconds)
                .toDouble());
        _policy = policy;
      });
    } catch (_) {
      if (mounted) setState(() => _error = failure);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _suggestRegion() async {
    final region =
        await (widget.regionSuggestion?.call() ?? suggestDiaRegion());
    if (!mounted || region == null) return;
    setState(() {
      if (!_zipEdited) _zip.text = region.zip;
      if (!_countryEdited) _country.text = region.country;
    });
  }

  Future<void> _detect() async {
    if (_detecting || widget.transcriptionClient == null) return;
    setState(() {
      _detecting = true;
      _error = null;
    });
    try {
      final slices = await detectRecordingTranscript(
          file: widget.file,
          store: widget.store,
          client: widget.transcriptionClient!,
          language: widget.language,
          isCancelled: () => !mounted);
      if (!mounted) return;
      final sentences = detectDiaSentences(slices);
      if (sentences.isEmpty) throw StateError('No speech detected');
      setState(() {
        widget.file.transcriptSlices = slices;
        _sentences = sentences;
        _select(_sentenceAtSelection(sentences, widget.source, slices) ?? 0);
      });
      await _saveDetectedBoundaries();
    } on TranscriptionException catch (error) {
      if (mounted) {
        setState(() => _error = error.slug == 'anonymous_recording_too_long'
            ? 'long'
            : error.kind == TranscriptionErrorKind.anonymousLimit
                ? 'quota'
                : error.kind == TranscriptionErrorKind.unauthorized
                    ? 'auth'
                    : 'detect');
      }
    } on FormatException {
      if (mounted) setState(() => _error = 'audio');
    } catch (_) {
      if (mounted) setState(() => _error = 'detect');
    } finally {
      if (mounted) setState(() => _detecting = false);
    }
  }

  Future<void> _saveDetectedBoundaries() async {
    if (mounted && _error == 'marks') setState(() => _error = null);
    try {
      await widget.onTranscriptDetected?.call(widget.file.transcriptSlices);
    } catch (_) {
      if (mounted) setState(() => _error = 'marks');
    }
  }

  void _select(int index) {
    _selected = index;
    final sentence = _sentences[index];
    final text = sentence.text;
    final source = widget.source;
    var selection = TextSelection.collapsed(offset: text.length);
    if (source != null &&
        _sentenceAtSelection(
                _sentences, source, widget.file.transcriptSlices) ==
            index) {
      final start = _sentenceSourceStart(sentence, source.text,
          _recordingSourceStart(widget.file.transcriptSlices, source.text))!;
      selection = TextSelection(
          baseOffset: source.selection.baseOffset - start,
          extentOffset: source.selection.extentOffset - start);
    }
    _correction.value = TextEditingValue(text: text, selection: selection);
    _receipt = null;
    _error = !_loading && _policy == null ? 'policy' : null;
  }

  Future<void> _changeSelection(int? index) async {
    if (_busy ||
        index == null ||
        index == _selected ||
        !await _confirmDiscard() ||
        !mounted) {
      return;
    }
    await _stopPlayback();
    if (mounted) setState(() => _select(index));
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final l10n = AppLocalizations.of(context);
    return await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                  title: Text(l10n.diaDiscard),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: Text(l10n.diaKeepEditing)),
                    TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: Text(l10n.diaDiscardAction)),
                  ],
                )) ??
        false;
  }

  Future<void> _close() async {
    if (_busy || !await _confirmDiscard() || !mounted) return;
    setState(() => _allowClose = true);
    Navigator.pop(context);
  }

  Future<void> _stopPlayback() async {
    await _player?.stop();
    if (mounted) setState(() => _playing = false);
  }

  Future<void> _listen() async {
    if (_playing) {
      await _stopPlayback();
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final wav = await readRecordingClip(
          widget.store, widget.file.id, _startByte, _endByte);
      if (_player == null) {
        _player = AudioPlayer();
        _player!.onPlayerComplete.listen((_) {
          if (mounted) setState(() => _playing = false);
        });
      }
      await _player!.play(kIsWeb
          ? UrlSource('data:audio/wav;base64,${base64Encode(wav)}')
          : BytesSource(wav));
      if (mounted) setState(() => _playing = true);
    } catch (_) {
      if (mounted) setState(() => _error = 'audio');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    if (_busy ||
        _detecting ||
        _clipTooLong ||
        !_consent ||
        _policy == null ||
        _correction.text.trim().isEmpty) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    var failure = 'audio';
    try {
      await _regionReady;
      if (!mounted) return;
      await _stopPlayback();
      final wav = await readRecordingClip(
          widget.store, widget.file.id, _startByte, _endByte);
      failure = 'send';
      final receipt = await _client.submit(
          wavBytes: wav,
          correction:
              _sentence?.replaceWith(_correction.text) ?? _correction.text,
          policy: _policy!,
          consent: _consent,
          zipCode: _zip.text,
          country: _country.text);
      if (mounted) setState(() => _receipt = receipt);
      // A preference write cannot turn a completed upload into a retry.
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('dia-region-zip', _zip.text);
        await prefs.setString('dia-region-country', _country.text);
      } catch (_) {}
    } catch (_) {
      if (mounted) setState(() => _error = failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _correction.dispose();
    _zip.dispose();
    _country.dispose();
    unawaited(_player?.dispose());
    if (widget.client == null) _client.dispose();
    super.dispose();
  }

  String _time(double seconds) =>
      '${seconds ~/ 60}:${(seconds.toInt() % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final policy = _policy;
    return PopScope(
      canPop: _allowClose || (!_busy && !_dirty),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy) _close();
      },
      child: AlertDialog(
        title: Text(l10n.diaCorrectSentence),
        content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
                child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_receipt != null) ...[
                  const Icon(Icons.check_circle_outline, size: 40),
                  Text(l10n.diaSuccess),
                  const SizedBox(height: 12),
                  Text(l10n.diaReceipt),
                  SelectableText(_receipt!.id),
                ] else ...[
                  if (!_detecting)
                    Text(_sentences.isEmpty
                        ? l10n.diaLegacyHelp
                        : l10n.diaSelectionHelp),
                  const SizedBox(height: 12),
                  if (_detecting) ...[
                    Text(l10n.diaDetectingSentences),
                    const LinearProgressIndicator(),
                  ] else if (_sentences.length > 1)
                    ExpansionTile(
                        key: const Key('dia-sentences'),
                        title: Text(l10n.diaChangeSentence),
                        children: [
                          ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 180),
                              child: RadioGroup<int>(
                                  groupValue: _selected,
                                  onChanged: _changeSelection,
                                  child: ListView.builder(
                                      shrinkWrap: true,
                                      itemCount: _sentences.length,
                                      itemBuilder: (context, index) =>
                                          RadioListTile<int>(
                                              key: ValueKey(
                                                  'dia-sentence-$index'),
                                              contentPadding: EdgeInsets.zero,
                                              title:
                                                  Text(_sentences[index].text),
                                              value: index,
                                              enabled: !_busy)))),
                        ])
                  else if (_sentences.isEmpty && _duration > 0) ...[
                    Text('${_time(_range.start)} – ${_time(_range.end)}'),
                    RangeSlider(
                        key: const Key('dia-audio-range'),
                        values: _range,
                        max: _duration,
                        labels:
                            RangeLabels(_time(_range.start), _time(_range.end)),
                        onChanged: _busy
                            ? null
                            : (range) {
                                unawaited(_stopPlayback());
                                setState(() => _range =
                                    range.end - range.start <=
                                            DiaContributionClient.maxClipSeconds
                                        ? range
                                        : range.start != _range.start
                                            ? RangeValues(
                                                range.start,
                                                range.start +
                                                    DiaContributionClient
                                                        .maxClipSeconds)
                                            : RangeValues(
                                                range.end -
                                                    DiaContributionClient
                                                        .maxClipSeconds,
                                                range.end));
                              }),
                  ],
                  if (_sentence != null)
                    Text(
                        '${_time(_startByte / WavFormat.standard.bytesPerSecond)} – ${_time(_endByte / WavFormat.standard.bytesPerSecond)}'),
                  TextButton.icon(
                      key: const Key('dia-listen'),
                      onPressed:
                          _busy || _endByte <= _startByte ? null : _listen,
                      icon: Icon(_playing ? Icons.stop : Icons.play_arrow),
                      label: Text(
                          _playing ? l10n.diaStopListening : l10n.diaListen)),
                  TextField(
                      key: const Key('dia-correction'),
                      controller: _correction,
                      enabled: !_busy && !_detecting,
                      autofocus: widget.source?.selection.isCollapsed == false,
                      minLines: 2,
                      maxLines: 6,
                      maxLength: 4000,
                      onChanged: (_) => setState(() {}),
                      decoration:
                          InputDecoration(labelText: l10n.diaCorrection)),
                  Text(l10n.diaScope),
                  if (_sentence != null &&
                      _sentence!.contextText != _sentence!.text)
                    Text(l10n.diaAudioContextHelp),
                  if (_clipTooLong)
                    Text(l10n.diaClipTooLong,
                        key: const Key('dia-clip-too-long')),
                  ExpansionTile(
                      title: Text(l10n.diaRegion),
                      subtitle: [_zip.text, _country.text]
                              .where((value) => value.isNotEmpty)
                              .isEmpty
                          ? null
                          : Text([_zip.text, _country.text]
                              .where((value) => value.isNotEmpty)
                              .join(' · ')),
                      children: [
                        TextField(
                            controller: _zip,
                            enabled: !_busy,
                            onChanged: (_) => setState(() => _zipEdited = true),
                            maxLength: 10,
                            decoration:
                                InputDecoration(labelText: l10n.diaZip)),
                        TextField(
                            controller: _country,
                            enabled: !_busy,
                            onChanged: (_) =>
                                setState(() => _countryEdited = true),
                            maxLength: 2,
                            textCapitalization: TextCapitalization.characters,
                            decoration:
                                InputDecoration(labelText: l10n.diaCountry)),
                      ]),
                  if (_loading) const LinearProgressIndicator(),
                  if (policy != null) ...[
                    ExpansionTile(
                        key: const Key('dia-terms'),
                        title: Text(l10n.diaTerms),
                        children: [
                          SelectableText(
                              '${policy.trainingTitle}\n\n${policy.trainingDescription}\n\n${policy.information}\n\n${policy.terms}\n\n${policy.privacyUrl}'),
                        ]),
                    CheckboxListTile(
                        key: const Key('dia-consent'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(l10n.diaConsent),
                        value: _consent,
                        onChanged: _busy
                            ? null
                            : (value) => setState(() => _consent = value!)),
                  ],
                  if (_error != null)
                    Text(
                        _error == 'long'
                            ? l10n.diaDetectTooLong
                            : _error == 'quota'
                                ? l10n.liveTranscriptionAnonymousLimit
                                : _error == 'auth'
                                    ? l10n.liveTranscriptionNotSignedIn
                                    : _error == 'policy'
                                        ? l10n.diaPolicyError
                                        : _error == 'audio'
                                            ? l10n.diaAudioError
                                            : _error == 'detect'
                                                ? l10n.diaDetectError
                                                : _error == 'marks'
                                                    ? l10n.diaMarksError
                                                    : l10n.diaError,
                        key: const Key('dia-error'),
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  if (_error == 'policy' ||
                      _error == 'detect' ||
                      _error == 'marks')
                    TextButton(
                        onPressed: _loading || _detecting
                            ? null
                            : _error == 'marks'
                                ? _saveDetectedBoundaries
                                : _error == 'detect'
                                    ? _detect
                                    : _load,
                        child: Text(l10n.commonRetry)),
                  if (_busy) const LinearProgressIndicator(),
                ],
              ],
            ))),
        actions: [
          TextButton(
              onPressed: _busy ? null : _close,
              child: Text(
                  _receipt == null ? l10n.commonCancel : l10n.commonClose)),
          if (_receipt != null && _sentences.length > 1)
            TextButton(
                onPressed: () => setState(() {
                      _select((_selected! + 1) % _sentences.length);
                      _consent = false;
                    }),
                child: Text(l10n.diaAnother)),
          if (_receipt == null)
            FilledButton(
                key: const Key('dia-submit'),
                onPressed: !_busy &&
                        !_detecting &&
                        _policy != null &&
                        _consent &&
                        _correction.text.trim().isNotEmpty &&
                        _endByte > _startByte &&
                        !_clipTooLong
                    ? _submit
                    : null,
                child: Text(l10n.diaSend)),
        ],
      ),
    );
  }
}
