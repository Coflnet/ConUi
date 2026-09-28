import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../backup/backup_create_screen.dart';
import '../backup/backup_service.dart';
import '../backup/backup_strings.dart';
import '../backup/restore_screen.dart';
import '../services/auth_service.dart';
import '../services/sync_service.dart';
import '../services/database_service.dart';

class SettingsScreen extends StatefulWidget {
  /// Overridable so tests can supply a BackupService backed by a temp-dir
  /// recording store instead of the real path_provider/file_picker
  /// platform channels (mirrors EventDetailScreen's injectable
  /// recordingFileStore). Left null in normal navigation (e.g. from
  /// HomeScreen), which is equivalent - the screen builds its own.
  final BackupService? backupService;

  const SettingsScreen({super.key, this.backupService});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _isSyncing = false;
  String? _lastSyncTime;
  int _pendingChanges = 0;

  late final BackupService _backupService;
  DateTime? _lastBackupAt;
  int _recordingsSpaceBytes = 0;
  int _newRecordingsSinceBackup = 0;
  bool _backupStatusLoaded = false;

  @override
  void initState() {
    super.initState();
    _backupService = widget.backupService ??
        BackupService(databaseService: context.read<DatabaseService>());
    _loadSyncStatus();
    _loadBackupStatus();
  }

  Future<void> _loadSyncStatus() async {
    final db = context.read<DatabaseService>();
    final pending = await db.getPendingChanges();
    if (!mounted) return;
    setState(() {
      _pendingChanges = pending.length;
    });
  }

  Future<void> _loadBackupStatus() async {
    final lastBackupAt = await _backupService.getLastBackupAt();
    final spaceBytes = await _backupService.recordingsSpaceBytes();
    final newSinceBackup =
        lastBackupAt == null ? 0 : await _backupService.recordingsCreatedAfter(lastBackupAt);
    if (!mounted) return;
    setState(() {
      _lastBackupAt = lastBackupAt;
      _recordingsSpaceBytes = spaceBytes;
      _newRecordingsSinceBackup = newSinceBackup;
      _backupStatusLoaded = true;
    });
  }

  Future<void> _openCreateBackup() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => BackupCreateScreen(backupService: _backupService)),
    );
    await _loadBackupStatus();
  }

  Future<void> _openRestore() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => RestoreScreen(backupService: _backupService)),
    );
    await _loadBackupStatus();
    await _loadSyncStatus();
  }

  Future<void> _forceSync() async {
    setState(() => _isSyncing = true);
    try {
      final syncService = context.read<SyncService>();
      await syncService.fullSync();
      await _loadSyncStatus();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sync completed successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sync failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Logout'),
        content: const Text(
            'Are you sure you want to logout? Unsynced data may be lost.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Logout'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final auth = context.read<AuthService>();
      await auth.logout();
    }
  }

  Future<void> _clearAllData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear All Data'),
        content: const Text(
            'This will permanently delete all local data. This action cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete Everything'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final db = context.read<DatabaseService>();
      await db.clearAllData();
      final auth = context.read<AuthService>();
      await auth.logout();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          // Sync Section
          _buildSectionHeader('Sync'),
          ListTile(
            leading: const Icon(Icons.sync),
            title: const Text('Force Sync'),
            subtitle: _pendingChanges > 0
                ? Text('$_pendingChanges pending changes')
                : const Text('All changes synced'),
            trailing: _isSyncing
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right),
            onTap: _isSyncing ? null : _forceSync,
          ),
          if (_lastSyncTime != null)
            ListTile(
              leading: const Icon(Icons.schedule),
              title: const Text('Last Sync'),
              subtitle: Text(_lastSyncTime!),
            ),

          const Divider(),

          // Backup Section
          _buildSectionHeader(BackupStrings.sectionTitle),
          ListTile(
            leading: const Icon(Icons.backup),
            title: const Text(BackupStrings.createTitle),
            subtitle: !_backupStatusLoaded
                ? const Text(BackupStrings.createSubtitleIdle)
                : Text(_lastBackupAt == null
                    ? BackupStrings.createSubtitleNever
                    : BackupStrings.createSubtitleLastBackup(
                        _formatDateTime(_lastBackupAt!))),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openCreateBackup,
          ),
          if (_backupStatusLoaded && _lastBackupAt != null && _newRecordingsSinceBackup > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                BackupStrings.newRecordingsReminder(_newRecordingsSinceBackup),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.tertiary,
                  fontSize: 12,
                ),
              ),
            ),
          ListTile(
            leading: const Icon(Icons.restore),
            title: const Text(BackupStrings.restoreTitle),
            subtitle: const Text(BackupStrings.restoreSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openRestore,
          ),
          ListTile(
            leading: const Icon(Icons.mic),
            title: const Text(BackupStrings.recordingsSpaceTitle),
            subtitle: Text(_backupStatusLoaded
                ? BackupStrings.bytesToHuman(_recordingsSpaceBytes)
                : '…'),
          ),
          ListTile(
            leading: Icon(Icons.contacts,
                color: Theme.of(context).colorScheme.primary),
            title: const Text('Import Contacts'),
            subtitle: const Text('Import from device contacts'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _importContacts(),
          ),

          const Divider(),

          // Account Section
          _buildSectionHeader('Account'),
          Consumer<AuthService>(
            builder: (context, auth, _) {
              return ListTile(
                leading: const Icon(Icons.person),
                title: const Text('Logged in as'),
                subtitle: Text(auth.userId ?? 'Unknown'),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.orange),
            title: const Text('Logout'),
            subtitle: const Text('Sign out of your account'),
            onTap: _logout,
          ),

          const Divider(),

          // Danger Zone
          _buildSectionHeader('Danger Zone', color: Colors.red),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            title:
                const Text('Clear All Data', style: TextStyle(color: Colors.red)),
            subtitle: const Text('Delete all local data permanently'),
            onTap: _clearAllData,
          ),

          const SizedBox(height: 32),

          // Version Info
          Center(
            child: Text(
              'Relationship Manager v1.0.0',
              style: TextStyle(color: Colors.grey[500], fontSize: 12),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: color ?? Colors.grey[600],
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    final local = dt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  Future<void> _importContacts() async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Contact import will request permissions')),
    );
    // TODO: Implement contact import. The `contacts_service` package this
    // was originally slated to use was removed from pubspec.yaml - it's
    // incompatible with the current Flutter engine (still references the
    // long-removed v1 PluginRegistry.Registrar Android embedding API,
    // which fails to compile) and was never actually called from here
    // anyway (this button only ever showed the placeholder snackbar
    // below). Pick a maintained alternative (e.g. `flutter_contacts`) when
    // implementing this for real.
    // This requires platform-specific permissions setup
  }
}
