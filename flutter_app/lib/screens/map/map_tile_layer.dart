import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

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
class StoryMapTileLayer extends StatelessWidget {
  const StoryMapTileLayer({super.key});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        TileLayer(
          urlTemplate: _osmTileUrlTemplate,
          userAgentPackageName: _osmUserAgentPackageName,
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
