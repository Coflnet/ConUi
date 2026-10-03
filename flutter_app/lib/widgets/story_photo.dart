import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/event.dart';
import '../l10n/gen/app_localizations.dart';
import '../services/database_service.dart';
import '../services/story_photo_service.dart';

/// A database-backed thumbnail; tapping opens the original with pan and zoom.
class StoryPhoto extends StatefulWidget {
  final AttachedFile file;
  final bool fullScreen;
  final double size;

  const StoryPhoto(
      {super.key, required this.file, this.fullScreen = false, this.size = 80});

  @override
  State<StoryPhoto> createState() => _StoryPhotoState();
}

class _StoryPhotoState extends State<StoryPhoto> {
  late Future<Uint8List> _bytes;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bytes = StoryPhotoService(context.read<DatabaseService>())
        .readPhoto(widget.file.id);
  }

  @override
  Widget build(BuildContext context) {
    final unavailable = Tooltip(
      message: AppLocalizations.of(context).storyPhotoUnavailable,
      child: widget.fullScreen
          ? Padding(padding: const EdgeInsets.all(24), child: Text(
              AppLocalizations.of(context).storyPhotoUnavailable, textAlign: TextAlign.center))
          : const Icon(Icons.broken_image),
    );
    final image = FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (context, snapshot) => snapshot.hasData
          ? Image.memory(snapshot.data!,
              fit: widget.fullScreen ? BoxFit.contain : BoxFit.cover,
              errorBuilder: (_, __, ___) => unavailable)
          : snapshot.hasError
              ? unavailable
              : const Center(child: CircularProgressIndicator()),
    );
    if (widget.fullScreen) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.file.fileName)),
        body: Center(child: InteractiveViewer(child: image)),
      );
    }
    return Semantics(
      label: widget.file.fileName, button: true,
      child: InkWell(
      onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => StoryPhoto(file: widget.file, fullScreen: true))),
      child: SizedBox(width: widget.size, height: widget.size, child: image),
    ));
  }
}
