import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../l10n/gen/app_localizations.dart';
import 'map_tile_layer.dart';

/// One reusable full-screen map for picking (or adjusting) a single
/// position: a pin fixed at the centre of the screen, moved by panning the
/// map underneath it - the classic "drop a pin" pattern, and simpler to get
/// right than a draggable marker for a screen with nothing else competing
/// for space. Returns the chosen [LatLng] via [Navigator.pop], or null if
/// the user backs out.
///
/// Reused by both AddEventScreen's "pick on map" place field action and the
/// place sheet's "adjust position" action, so there is exactly one map
/// picker implementation in the app.
class LocationPickerScreen extends StatefulWidget {
  final LatLng initialPosition;
  final double initialZoom;

  const LocationPickerScreen({
    super.key,
    required this.initialPosition,
    this.initialZoom = 15,
  });

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  late final MapController _mapController = MapController();
  late LatLng _position = widget.initialPosition;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.locationPickerTitle)),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Text(l10n.locationPickerInstructions, textAlign: TextAlign.center),
          ),
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: widget.initialPosition,
                    initialZoom: widget.initialZoom,
                    onPositionChanged: (position, hasGesture) {
                      setState(() => _position = position.center ?? _position);
                    },
                  ),
                  children: const [StoryMapTileLayer()],
                ),
                const IgnorePointer(
                  child: Padding(
                    // Optically centre the pin's tip, not its icon centre.
                    padding: EdgeInsets.only(bottom: 24),
                    child: Icon(Icons.location_pin, size: 48, color: Colors.red),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.pop(context, _position),
        icon: const Icon(Icons.check),
        label: Text(l10n.locationPickerUse),
      ),
    );
  }
}
