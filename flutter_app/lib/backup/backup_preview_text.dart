import '../l10n/gen/app_localizations.dart';

/// "This backup will include"/"This backup contains" body text: people,
/// connections, places, stories, objects, in that order, joined with ", ",
/// or an "empty" message when there's nothing at all. Shared by
/// BackupCreateScreen's plan preview and RestoreScreen's archive preview -
/// both describe a [counts] map with the same keys (see BackupManifest).
String backupPreviewCountsText(AppLocalizations l10n, Map<String, int> counts) {
  final parts = <String>[
    if ((counts['persons'] ?? 0) > 0) l10n.backupPreviewPersons(counts['persons']!),
    if ((counts['connections'] ?? 0) > 0)
      l10n.backupPreviewConnections(counts['connections']!),
    if ((counts['places'] ?? 0) > 0) l10n.backupPreviewPlaces(counts['places']!),
    if ((counts['events'] ?? 0) > 0) l10n.backupPreviewStories(counts['events']!),
    if ((counts['objects'] ?? 0) > 0) l10n.backupPreviewObjects(counts['objects']!),
  ];
  return parts.isEmpty ? l10n.backupPreviewEmpty : parts.join(', ');
}
