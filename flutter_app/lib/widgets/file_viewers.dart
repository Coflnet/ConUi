import 'dart:io';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import '../services/encryption_service.dart';
import '../services/database_service.dart';
import '../models/models.dart';

/// Widget for displaying images from encrypted storage
class EncryptedImageViewer extends StatefulWidget {
  final String fileId;
  final String? fileName;
  final BoxFit fit;
  final double? width;
  final double? height;

  const EncryptedImageViewer({
    super.key,
    required this.fileId,
    this.fileName,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
  });

  @override
  State<EncryptedImageViewer> createState() => _EncryptedImageViewerState();
}

class _EncryptedImageViewerState extends State<EncryptedImageViewer> {
  File? _decryptedFile;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      final encryptionService = EncryptionService.instance;
      if (encryptionService == null) {
        throw Exception('Encryption service not initialized');
      }

      // Get the encrypted file path from storage
      final dir = await getApplicationDocumentsDirectory();
      final encryptedPath = '${dir.path}/files/${widget.fileId}.enc';
      final encryptedFile = File(encryptedPath);

      if (!await encryptedFile.exists()) {
        throw Exception('File not found');
      }

      // Decrypt the file to a temp location
      final decryptedPath = '${dir.path}/temp/${widget.fileId}';
      final decryptedDir = Directory('${dir.path}/temp');
      if (!await decryptedDir.exists()) {
        await decryptedDir.create(recursive: true);
      }

      final encryptedBytes = await encryptedFile.readAsBytes();
      final decryptedBytes = encryptionService.decryptBytes(encryptedBytes);

      final decryptedFile = File(decryptedPath);
      await decryptedFile.writeAsBytes(decryptedBytes);

      if (mounted) {
        setState(() {
          _decryptedFile = decryptedFile;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    // Clean up temp file
    _decryptedFile?.delete().catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null || _decryptedFile == null) {
      return Container(
        width: widget.width,
        height: widget.height,
        color: Colors.grey[300],
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.broken_image, color: Colors.grey[600]),
            const SizedBox(height: 4),
            Text('Error loading image',
                style: TextStyle(color: Colors.grey[600], fontSize: 12)),
          ],
        ),
      );
    }

    return Image.file(
      _decryptedFile!,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      errorBuilder: (context, error, stack) => Container(
        width: widget.width,
        height: widget.height,
        color: Colors.grey[300],
        child: Icon(Icons.broken_image, color: Colors.grey[600]),
      ),
    );
  }
}

/// Full-screen image viewer with zoom support
class FullScreenImageViewer extends StatefulWidget {
  final String fileId;
  final String? title;

  const FullScreenImageViewer({
    super.key,
    required this.fileId,
    this.title,
  });

  @override
  State<FullScreenImageViewer> createState() => _FullScreenImageViewerState();
}

class _FullScreenImageViewerState extends State<FullScreenImageViewer> {
  File? _decryptedFile;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      final encryptionService = EncryptionService.instance;
      if (encryptionService == null) return;

      final dir = await getApplicationDocumentsDirectory();
      final encryptedPath = '${dir.path}/files/${widget.fileId}.enc';
      final encryptedFile = File(encryptedPath);

      if (!await encryptedFile.exists()) return;

      final decryptedPath = '${dir.path}/temp/full_${widget.fileId}';
      final decryptedDir = Directory('${dir.path}/temp');
      if (!await decryptedDir.exists()) {
        await decryptedDir.create(recursive: true);
      }

      final encryptedBytes = await encryptedFile.readAsBytes();
      final decryptedBytes = encryptionService.decryptBytes(encryptedBytes);

      final decryptedFile = File(decryptedPath);
      await decryptedFile.writeAsBytes(decryptedBytes);

      if (mounted) {
        setState(() {
          _decryptedFile = decryptedFile;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _decryptedFile?.delete().catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: widget.title != null ? Text(widget.title!) : null,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _decryptedFile != null
              ? InteractiveViewer(
                  child: Center(
                    child: Image.file(_decryptedFile!),
                  ),
                )
              : const Center(
                  child: Text('Failed to load image',
                      style: TextStyle(color: Colors.white)),
                ),
    );
  }
}

/// Audio player widget for encrypted audio files
class EncryptedAudioPlayer extends StatefulWidget {
  final String fileId;
  final String? fileName;
  final bool compact;

  const EncryptedAudioPlayer({
    super.key,
    required this.fileId,
    this.fileName,
    this.compact = false,
  });

  @override
  State<EncryptedAudioPlayer> createState() => _EncryptedAudioPlayerState();
}

class _EncryptedAudioPlayerState extends State<EncryptedAudioPlayer> {
  final AudioPlayer _audioPlayer = AudioPlayer();
  File? _decryptedFile;
  bool _loading = true;
  bool _isPlaying = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadAudio();
    _setupListeners();
  }

  void _setupListeners() {
    _audioPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state == PlayerState.playing;
        });
      }
    });

    _audioPlayer.onDurationChanged.listen((duration) {
      if (mounted) setState(() => _duration = duration);
    });

    _audioPlayer.onPositionChanged.listen((position) {
      if (mounted) setState(() => _position = position);
    });

    _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _position = Duration.zero;
        });
      }
    });
  }

  Future<void> _loadAudio() async {
    try {
      final encryptionService = EncryptionService.instance;
      if (encryptionService == null) {
        throw Exception('Encryption service not initialized');
      }

      final dir = await getApplicationDocumentsDirectory();
      final encryptedPath = '${dir.path}/files/${widget.fileId}.enc';
      final encryptedFile = File(encryptedPath);

      if (!await encryptedFile.exists()) {
        throw Exception('File not found');
      }

      final ext = widget.fileName?.split('.').last ?? 'mp3';
      final decryptedPath = '${dir.path}/temp/audio_${widget.fileId}.$ext';
      final decryptedDir = Directory('${dir.path}/temp');
      if (!await decryptedDir.exists()) {
        await decryptedDir.create(recursive: true);
      }

      final encryptedBytes = await encryptedFile.readAsBytes();
      final decryptedBytes = encryptionService.decryptBytes(encryptedBytes);

      final decryptedFile = File(decryptedPath);
      await decryptedFile.writeAsBytes(decryptedBytes);

      if (mounted) {
        setState(() {
          _decryptedFile = decryptedFile;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _togglePlayPause() async {
    if (_decryptedFile == null) return;

    if (_isPlaying) {
      await _audioPlayer.pause();
    } else {
      await _audioPlayer.play(DeviceFileSource(_decryptedFile!.path));
    }
  }

  Future<void> _seek(double value) async {
    final position = Duration(milliseconds: value.toInt());
    await _audioPlayer.seek(position);
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _decryptedFile?.delete().catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null || _decryptedFile == null) {
      return ListTile(
        leading: const Icon(Icons.error_outline, color: Colors.red),
        title: Text(widget.fileName ?? 'Audio file'),
        subtitle: const Text('Failed to load audio'),
      );
    }

    if (widget.compact) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(_isPlaying
                ? Icons.pause_circle_filled
                : Icons.play_circle_filled),
            iconSize: 40,
            color: Theme.of(context).colorScheme.primary,
            onPressed: _togglePlayPause,
          ),
          Text(_formatDuration(_position)),
        ],
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.audio_file,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.fileName ?? 'Audio',
                    style: Theme.of(context).textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                IconButton(
                  icon: Icon(_isPlaying
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_filled),
                  iconSize: 48,
                  color: Theme.of(context).colorScheme.primary,
                  onPressed: _togglePlayPause,
                ),
                Expanded(
                  child: Column(
                    children: [
                      Slider(
                        value: _position.inMilliseconds.toDouble(),
                        min: 0,
                        max: _duration.inMilliseconds
                            .toDouble()
                            .clamp(1, double.infinity),
                        onChanged: _seek,
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(_formatDuration(_position)),
                            Text(_formatDuration(_duration)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Thumbnail widget for attached files (images show preview, audio shows icon)
class AttachedFileThumbnail extends StatelessWidget {
  final AttachedFile file;
  final double size;
  final VoidCallback? onTap;

  const AttachedFileThumbnail({
    super.key,
    required this.file,
    this.size = 60,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isImage = file.mimeType.startsWith('image/');
    final isAudio = file.mimeType.startsWith('audio/');

    return GestureDetector(
      onTap: onTap ?? () => _openFile(context),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.grey[200],
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
        child: isImage
            ? EncryptedImageViewer(
                fileId: file.id,
                fileName: file.fileName,
                fit: BoxFit.cover,
              )
            : Center(
                child: Icon(
                  isAudio ? Icons.audiotrack : Icons.insert_drive_file,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
      ),
    );
  }

  void _openFile(BuildContext context) {
    final isImage = file.mimeType.startsWith('image/');
    final isAudio = file.mimeType.startsWith('audio/');

    if (isImage) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => FullScreenImageViewer(
            fileId: file.id,
            title: file.fileName,
          ),
        ),
      );
    } else if (isAudio) {
      showModalBottomSheet(
        context: context,
        builder: (_) => Padding(
          padding: const EdgeInsets.all(16),
          child: EncryptedAudioPlayer(
            fileId: file.id,
            fileName: file.fileName,
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unsupported file type')),
      );
    }
  }
}

/// Grid view for displaying multiple attached files
class AttachedFilesGrid extends StatelessWidget {
  final List<AttachedFile> files;
  final int crossAxisCount;

  const AttachedFilesGrid({
    super.key,
    required this.files,
    this.crossAxisCount = 4,
  });

  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) {
      return const SizedBox.shrink();
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: files.length,
      itemBuilder: (context, index) {
        return AttachedFileThumbnail(file: files[index]);
      },
    );
  }
}
