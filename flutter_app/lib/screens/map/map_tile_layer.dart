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
        const SimpleAttributionWidget(
          source: Text('OpenStreetMap contributors'),
        ),
      ],
    );
  }
}
