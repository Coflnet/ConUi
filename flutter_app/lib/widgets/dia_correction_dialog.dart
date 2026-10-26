import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/gen/app_localizations.dart';
import '../models/models.dart';
import '../services/dia_contribution_client.dart';
import '../services/recording_clip.dart';
import '../services/recording_file_store.dart';

class DiaCorrectionButton extends StatelessWidget {
  final AttachedFile file;
  final RecordingFileStore store;
  const DiaCorrectionButton(
      {super.key, required this.file, required this.store});

  @override
  Widget build(BuildContext context) => TextButton.icon(
      key: ValueKey('dia-correct-${file.id}'),
      icon: const Icon(Icons.spellcheck),
      label: Text(AppLocalizations.of(context).diaCorrectSentence),
      onPressed: () => showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => DiaCorrectionDialog(file: file, store: store)));
}

class DiaCorrectionDialog extends StatefulWidget {
  final AttachedFile file;
  final RecordingFileStore store;
  final DiaContributionClient? client;
  const DiaCorrectionDialog(
      {super.key, required this.file, required this.store, this.client});

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
  RangeValues _range = const RangeValues(0, 0);
  double _duration = 0;

  List<RecordingTranscriptSlice> get _slices => widget.file.transcriptSlices;
  String get _initialText => _selected == null ? '' : _slices[_selected!].text;
  bool get _dirty => _receipt == null && _correction.text != _initialText;
  int get _startByte => _selected != null
      ? _slices[_selected!].startByte
      : (_range.start * WavFormat.standard.sampleRate).round() *
          WavFormat.standard.blockAlign;
  int get _endByte => _selected != null
      ? _slices[_selected!].endByte
      : (_range.end * WavFormat.standard.sampleRate).round() *
          WavFormat.standard.blockAlign;

  bool get _clipTooLong =>
      _endByte - _startByte >
      DiaContributionClient.maxWavBytes - wavHeaderLength;

  @override
  void initState() {
    super.initState();
    if (_slices.isNotEmpty) _select(0);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    var failure = 'audio';
    try {
      final prefs = await SharedPreferences.getInstance();
      final size = await widget.store.size(widget.file.id);
      failure = 'policy';
      final policy = await _client.fetchPolicy();
      if (!mounted) return;
      _zip.text = prefs.getString('dia-region-zip') ?? '';
      _country.text = prefs.getString('dia-region-country') ?? '';
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

  void _select(int index) {
    _selected = index;
    _correction.text = _slices[index].text;
    _receipt = null;
    _error = null;
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
      await _stopPlayback();
      final wav = await readRecordingClip(
          widget.store, widget.file.id, _startByte, _endByte);
      failure = 'send';
      final receipt = await _client.submit(
          wavBytes: wav,
          correction: _correction.text,
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
                  Text(_slices.isEmpty
                      ? l10n.diaLegacyHelp
                      : l10n.diaSelectionHelp),
                  const SizedBox(height: 12),
                  if (_slices.isNotEmpty) ...[
                    Text(l10n.diaSelectSentence),
                    ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 180),
                        child: RadioGroup<int>(
                          groupValue: _selected,
                          onChanged: _changeSelection,
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: _slices.length,
                            itemBuilder: (context, index) => RadioListTile<int>(
                              key: ValueKey('dia-sentence-$index'),
                              contentPadding: EdgeInsets.zero,
                              title: Text(_slices[index].text),
                              value: index,
                              enabled: !_busy,
                            ),
                          ),
                        )),
                  ] else if (_duration > 0) ...[
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
                      enabled: !_busy,
                      minLines: 2,
                      maxLines: 6,
                      maxLength: 4000,
                      onChanged: (_) => setState(() {}),
                      decoration:
                          InputDecoration(labelText: l10n.diaCorrection)),
                  Text(l10n.diaScope),
                  if (_clipTooLong)
                    Text(l10n.diaClipTooLong,
                        key: const Key('dia-clip-too-long')),
                  ExpansionTile(title: Text(l10n.diaRegion), children: [
                    TextField(
                        controller: _zip,
                        enabled: !_busy && !_loading,
                        maxLength: 10,
                        decoration: InputDecoration(labelText: l10n.diaZip)),
                    TextField(
                        controller: _country,
                        enabled: !_busy && !_loading,
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
                        _error == 'policy'
                            ? l10n.diaPolicyError
                            : _error == 'audio'
                                ? l10n.diaAudioError
                                : l10n.diaError,
                        key: const Key('dia-error'),
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  if (_error == 'policy')
                    TextButton(
                        onPressed: _loading ? null : _load,
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
          if (_receipt != null && _slices.length > 1)
            TextButton(
                onPressed: () => setState(() {
                      _select((_selected! + 1) % _slices.length);
                      _consent = false;
                    }),
                child: Text(l10n.diaAnother)),
          if (_receipt == null)
            FilledButton(
                key: const Key('dia-submit'),
                onPressed: !_busy &&
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
