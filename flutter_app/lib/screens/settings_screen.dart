import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../backup/backup_byte_format.dart';
import '../backup/backup_create_screen.dart';
import '../backup/backup_service.dart';
import '../backup/restore_screen.dart';
import '../l10n/gen/app_localizations.dart';
import '../services/app_settings_service.dart';
import '../services/auth_service.dart';
import '../services/sync_service.dart';
import '../services/database_service.dart';
import 'login_screen.dart';

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
    final l10n = AppLocalizations.of(context);
    setState(() => _isSyncing = true);
    try {
      final syncService = context.read<SyncService>();
      await syncService.fullSync();
      await _loadSyncStatus();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(syncService.needsSignIn
              ? l10n.homeSyncSignInRequired
              : syncService.needsEncryptionPassword
                  ? l10n.homeSyncPasswordRequired
                  : syncService.lastError != null
                      ? l10n.settingsSyncFailed(syncService.lastError!)
                      : l10n.settingsSyncCompleted)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.settingsSyncFailed(e.toString()))),
        );
      }
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  Future<void> _logout() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.settingsLogoutConfirmTitle),
        content: Text(l10n.settingsLogoutConfirmBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.commonCancel)),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(l10n.settingsLogout),
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
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.settingsClearAllDataConfirmTitle),
        content: Text(l10n.settingsClearAllDataConfirmBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.commonCancel)),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(l10n.settingsClearAllDataConfirmButton),
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

  /// Shows a simple "pick one" dialog - big, obvious radio options rather
  /// than a dropdown/segmented control, matching the app's non-technical,
  /// often-older audience.
  ///
  /// Returns the picked value wrapped in a 1-tuple, or null if the dialog
  /// was dismissed without picking anything - needed because [T] (e.g.
  /// `Locale?`) can itself legitimately be null (the "System"/"Automatic"
  /// option), which would otherwise be indistinguishable from a dismiss.
  Future<(T,)?> _pickOption<T>(
    String title,
    List<(T value, String label)> options,
    T current,
  ) {
    return showDialog<(T,)>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(title),
        children: [
          RadioGroup<T>(
            groupValue: current,
            onChanged: (v) => Navigator.pop(context, (v as T,)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (value, label) in options)
                  RadioListTile<T>(title: Text(label), value: value),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAppLanguage() async {
    final l10n = AppLocalizations.of(context);
    final settings = context.read<AppSettingsService>();
    final chosen = await _pickOption<Locale?>(
      l10n.settingsLanguageApp,
      [
        (null, l10n.settingsLanguageSystem),
        (const Locale('de'), l10n.settingsLanguageGerman),
        (const Locale('en'), l10n.settingsLanguageEnglish),
      ],
      settings.languageOverride,
    );
    if (chosen != null) {
      await settings.setLanguageOverride(chosen.$1);
    }
  }

  Future<void> _pickRecordingLanguage() async {
    final l10n = AppLocalizations.of(context);
    final settings = context.read<AppSettingsService>();
    final chosen = await _pickOption<String?>(
      l10n.settingsRecordingLanguage,
      [
        (null, l10n.settingsRecordingLanguageAutomatic),
        ('de', l10n.settingsLanguageGerman),
        ('en', l10n.settingsLanguageEnglish),
      ],
      settings.recordingLanguageOverride,
    );
    if (chosen != null) {
      await settings.setRecordingLanguageOverride(chosen.$1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final appSettings = context.watch<AppSettingsService>();
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: ListView(
        children: [
          // Sync Section
          _buildSectionHeader(l10n.settingsSyncSection),
          ListTile(
            leading: const Icon(Icons.sync),
            title: Text(l10n.settingsForceSync),
            subtitle: Text(l10n.settingsPendingChanges(_pendingChanges)),
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
              title: Text(l10n.settingsLastSync),
              subtitle: Text(_lastSyncTime!),
            ),

          const Divider(),

          // Language Section
          _buildSectionHeader(l10n.settingsLanguageSection),
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(l10n.settingsLanguageApp),
            subtitle: Text(_languageLabel(l10n, appSettings.languageOverride)),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickAppLanguage,
          ),
          ListTile(
            leading: const Icon(Icons.mic_external_on),
            title: Text(l10n.settingsRecordingLanguage),
            subtitle: Text(_recordingLanguageLabel(
                l10n, appSettings.recordingLanguageOverride)),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickRecordingLanguage,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              l10n.settingsRecordingLanguageHelp,
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
            ),
          ),

          const Divider(),

          // Backup Section
          _buildSectionHeader(l10n.backupSectionTitle),
          ListTile(
            leading: const Icon(Icons.backup),
            title: Text(l10n.backupCreateTitle),
            subtitle: !_backupStatusLoaded
                ? Text(l10n.backupCreateSubtitleIdle)
                : Text(_lastBackupAt == null
                    ? l10n.backupCreateSubtitleNever
                    : l10n.backupCreateSubtitleLastBackup(
                        _formatDateTime(_lastBackupAt!))),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openCreateBackup,
          ),
          if (_backupStatusLoaded && _lastBackupAt != null && _newRecordingsSinceBackup > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                l10n.backupNewRecordingsReminder(_newRecordingsSinceBackup),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.tertiary,
                  fontSize: 12,
                ),
              ),
            ),
          ListTile(
            leading: const Icon(Icons.restore),
            title: Text(l10n.backupRestoreTitle),
            subtitle: Text(l10n.backupRestoreSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openRestore,
          ),
          ListTile(
            leading: const Icon(Icons.mic),
            title: Text(l10n.backupRecordingsSpaceTitle),
            subtitle: Text(_backupStatusLoaded
                ? BackupByteFormat.human(_recordingsSpaceBytes)
                : '…'),
          ),
          ListTile(
            leading: Icon(Icons.contacts,
                color: Theme.of(context).colorScheme.primary),
            title: Text(l10n.settingsImportContactsTitle),
            subtitle: Text(l10n.settingsImportContactsSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _importContacts(),
          ),

          const Divider(),

          // Account Section
          _buildSectionHeader(l10n.settingsAccountSection),
          Consumer<AuthService>(
            builder: (context, auth, _) {
              if (!auth.isAuthenticated) {
                return ListTile(
                  leading: const Icon(Icons.login),
                  title: Text(l10n.loginAccountButton),
                  subtitle: Text(l10n.loginContinueExplainer),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const LoginScreen())),
                );
              }
              return ListTile(
                leading: const Icon(Icons.person),
                title: Text(l10n.settingsLoggedInAs),
                subtitle: Text(auth.userId ?? l10n.settingsUnknownUser),
              );
            },
          ),
          if (context.watch<AuthService>().isAuthenticated)
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.orange),
              title: Text(l10n.settingsLogout),
              subtitle: Text(l10n.settingsLogoutSubtitle),
              onTap: _logout,
            ),

          const Divider(),

          // Danger Zone
          _buildSectionHeader(l10n.settingsDangerZoneSection, color: Colors.red),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            title: Text(l10n.settingsClearAllData,
                style: const TextStyle(color: Colors.red)),
            subtitle: Text(l10n.settingsClearAllDataSubtitle),
            onTap: _clearAllData,
          ),

          const SizedBox(height: 32),

          // Version Info
          Center(
            child: Text(
              l10n.settingsVersion('1.0.0'),
              style: TextStyle(color: Colors.grey[500], fontSize: 12),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  String _languageLabel(AppLocalizations l10n, Locale? override) {
    switch (override?.languageCode) {
      case 'de':
        return l10n.settingsLanguageGerman;
      case 'en':
        return l10n.settingsLanguageEnglish;
      default:
        return l10n.settingsLanguageSystem;
    }
  }

  String _recordingLanguageLabel(AppLocalizations l10n, String? override) {
    switch (override) {
      case 'de':
        return l10n.settingsLanguageGerman;
      case 'en':
        return l10n.settingsLanguageEnglish;
      default:
        return l10n.settingsRecordingLanguageAutomatic;
    }
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
    final locale = Localizations.localeOf(context).toString();
    return DateFormat.yMd(locale).add_Hm().format(dt.toLocal());
  }

  Future<void> _importContacts() async {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).settingsImportContactsPlaceholder)),
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
