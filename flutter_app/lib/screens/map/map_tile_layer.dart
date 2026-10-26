import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../l10n/gen/app_localizations.dart';

/// Tile source and its required visible attribution - both mandated by the
/// OpenStreetMap tile usage policy
/// (https://operations.osmfoundation.org/policies/tiles/): a real (not
/// "com.example...") identifier in the tile request's User-Agent, and the
/// "© OpenStreetMap contributors" credit always visible on screen, not
/// hidden behind a toggle. Shared by every map in the app so there is
/// exactly one place that knows the tile URL.
const String _osmTileUrlTemplate = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const String _osmUserAgentPackageName = 'com.coflnet.relationshipmanager';

/// The OpenStreetMap tile layer plus its always-visible attribution, shared
/// by every [FlutterMap] in the app (the story map, the place sheet's small
/// map, and [LocationPickerScreen]) as one of its `children`.
class StoryMapTileLayer extends StatefulWidget {
  const StoryMapTileLayer({super.key});

  @override
  State<StoryMapTileLayer> createState() => _StoryMapTileLayerState();
}

class _StoryMapTileLayerState extends State<StoryMapTileLayer> {
  Key? _tileLayerKey = UniqueKey();
  bool _failed = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tileLayerKey = _tileLayerKey;
    return Stack(
      children: [
        if (_tileLayerKey != null)
          TileLayer(
            key: _tileLayerKey,
            urlTemplate: _osmTileUrlTemplate,
            userAgentPackageName: _osmUserAgentPackageName,
            evictErrorTileStrategy: EvictErrorTileStrategy.dispose,
            errorTileCallback: (_, __, ___) {
              // Cached failures can arrive while the layer builds or disposes.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && _tileLayerKey == tileLayerKey && !_failed) {
                  setState(() => _failed = true);
                }
              });
              WidgetsBinding.instance.ensureVisualUpdate();
            },
          ),
        if (_failed)
          Positioned(
            top: 8,
            left: 8,
            right: 8,
            child: Material(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    Expanded(child: Text(l10n.mapTilesUnavailable)),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _failed = false;
                          _tileLayerKey = null;
                        });
                        // Dispose and evict failed images before remounting:
                        // replacing the key in one frame can reuse cached errors.
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) {
                            setState(() => _tileLayerKey = UniqueKey());
                          }
                        });
                      },
                      child: Text(l10n.commonRetry),
                    ),
                  ],
                ),
              ),
            ),
          ),
        // A minimal attribution box built here (not flutter_map's own
        // SimpleAttributionWidget): that widget's internal Row reports a
        // huge RenderFlex overflow when nested inside this Stack instead
        // of being a direct top-level FlutterMap child - reproducible even
        // at a full-screen map size. This is simple enough to fully
        // control and avoids the issue entirely.
        Align(
          alignment: Alignment.bottomRight,
          child: Container(
            color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.8),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text(
              '© OpenStreetMap contributors',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ),
      ],
    );
  }
}
