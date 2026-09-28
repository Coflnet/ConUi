import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// A single map marker the user can drag to reposition.
///
/// flutter_map 6 has no built-in draggable marker, so this converts each
/// pointer-drag delta (in on-screen logical pixels) into a lat/lng delta
/// using the map's current camera transform - the same technique the
/// package itself uses internally for panning - which keeps the drag
/// feeling correct at any zoom level or map rotation.
///
/// Used for the "drop a pin, then adjust it" step of quick-adding a story:
/// [position] is the single source of truth for where the pin is, shared
/// with whatever reads it to save the story.
class DraggablePinMarker extends StatelessWidget {
  final MapController mapController;
  final ValueNotifier<LatLng> position;

  const DraggablePinMarker({
    super.key,
    required this.mapController,
    required this.position,
  });

  void _onPanUpdate(DragUpdateDetails details) {
    final camera = mapController.camera;
    final screenPoint = camera.latLngToScreenPoint(position.value);
    final movedPoint = math.Point<double>(
      screenPoint.x + details.delta.dx,
      screenPoint.y + details.delta.dy,
    );
    position.value = camera.pointToLatLng(movedPoint);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<LatLng>(
      valueListenable: position,
      builder: (context, point, _) {
        return MarkerLayer(
          markers: [
            Marker(
              point: point,
              width: 48,
              height: 48,
              alignment: Alignment.topCenter,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanUpdate: _onPanUpdate,
                child: Semantics(
                  label: 'New story location, drag to adjust',
                  child: const Icon(Icons.location_pin, size: 48, color: Colors.red),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
