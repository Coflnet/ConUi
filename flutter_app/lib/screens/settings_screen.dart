import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/sync_service.dart';
import '../services/database_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _isSyncing = false;
  String? _lastSyncTime;
  int _pendingChanges = 0;

  @override
  void initState() {
    super.initState();
    _loadSyncStatus();
  }

  Future<void> _loadSyncStatus() async {
    final db = context.read<DatabaseService>();
    final pending = await db.getPendingChanges();
    setState(() {
      _pendingChanges = pending.length;
    });
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
    return ListView(
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

        // Data Section
        _buildSectionHeader('Data'),
        ListTile(
          leading: const Icon(Icons.download),
          title: const Text('Export Data'),
          subtitle: const Text('Download your data as JSON'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Export feature coming soon')),
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.upload),
          title: const Text('Import Data'),
          subtitle: const Text('Import data from JSON file'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Import feature coming soon')),
            );
          },
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

  Future<void> _importContacts() async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Contact import will request permissions')),
    );
    // TODO: Implement contact import using contacts_service package
    // This requires platform-specific permissions setup
  }
}
