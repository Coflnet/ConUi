import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/models.dart';
import '../../services/database_service.dart';

class PlacesScreen extends StatefulWidget {
  const PlacesScreen({super.key});

  @override
  State<PlacesScreen> createState() => _PlacesScreenState();
}

class _PlacesScreenState extends State<PlacesScreen> {
  bool _showMap = false;
  final MapController _mapController = MapController();

  // Map position persistence keys
  static const String _mapLatKey = 'places_map_lat';
  static const String _mapLngKey = 'places_map_lng';
  static const String _mapZoomKey = 'places_map_zoom';

  // Default map position
  double _mapLat = 48.8566; // Paris
  double _mapLng = 2.3522;
  double _mapZoom = 10;
  bool _mapInitialized = false;

  @override
  void initState() {
    super.initState();
    _loadMapPosition();
  }

  Future<void> _loadMapPosition() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _mapLat = prefs.getDouble(_mapLatKey) ?? _mapLat;
      _mapLng = prefs.getDouble(_mapLngKey) ?? _mapLng;
      _mapZoom = prefs.getDouble(_mapZoomKey) ?? _mapZoom;
      _mapInitialized = true;
    });
  }

  Future<void> _saveMapPosition() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_mapLatKey, _mapController.camera.center.latitude);
    await prefs.setDouble(_mapLngKey, _mapController.camera.center.longitude);
    await prefs.setDouble(_mapZoomKey, _mapController.camera.zoom);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<DatabaseService>(
      builder: (context, db, _) {
        return FutureBuilder<List<Place>>(
          future: db.getPlaces(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            final places = snapshot.data ?? [];

            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(
                          value: false,
                          label: Text('List'),
                          icon: Icon(Icons.list)),
                      ButtonSegment(
                          value: true,
                          label: Text('Map'),
                          icon: Icon(Icons.map)),
                    ],
                    selected: {_showMap},
                    onSelectionChanged: (v) =>
                        setState(() => _showMap = v.first),
                  ),
                ),
                Expanded(
                  child:
                      _showMap ? _buildMapView(places) : _buildListView(places),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildListView(List<Place> places) {
    if (places.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.place_outlined, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text('No places yet',
                style: TextStyle(fontSize: 18, color: Colors.grey[600])),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => _addPlace(),
              icon: const Icon(Icons.add),
              label: const Text('Add Place'),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: places.length,
      itemBuilder: (context, index) {
        final place = places[index];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            child: const Icon(Icons.place),
          ),
          title: Text(place.name),
          subtitle: Text(place.address ??
              '${place.latitude.toStringAsFixed(4)}, ${place.longitude.toStringAsFixed(4)}'),
          trailing: place.category != null
              ? Chip(label: Text(place.category!))
              : null,
          onTap: () => _showPlaceDetails(place),
        );
      },
    );
  }

  Widget _buildMapView(List<Place> places) {
    if (!_mapInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: LatLng(_mapLat, _mapLng),
        initialZoom: _mapZoom,
        onTap: (tapPosition, point) => _showQuickAddPlaceDialog(point),
        onLongPress: (tapPosition, point) => _addPlaceAtLocation(point),
        onPositionChanged: (position, hasGesture) {
          if (hasGesture) {
            _saveMapPosition();
          }
        },
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.example.relationship_manager',
        ),
        MarkerLayer(
          markers: places
              .map((place) => Marker(
                    point: LatLng(place.latitude, place.longitude),
                    width: 80,
                    height: 80,
                    child: GestureDetector(
                      onTap: () => _showPlaceDetails(place),
                      child: Column(
                        children: [
                          const Icon(Icons.location_pin,
                              color: Colors.red, size: 40),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(place.name,
                                style: const TextStyle(fontSize: 10)),
                          ),
                        ],
                      ),
                    ),
                  ))
              .toList(),
        ),
      ],
    );
  }

  /// Quick dialog for adding a place when tapping on the map - just name field
  void _showQuickAddPlaceDialog(LatLng point) {
    final nameController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Place'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Location: ${point.latitude.toStringAsFixed(4)}, ${point.longitude.toStringAsFixed(4)}',
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Place Name *',
                hintText: 'Enter a name for this place',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
              textCapitalization: TextCapitalization.words,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              if (nameController.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter a name')),
                );
                return;
              }
              final db = context.read<DatabaseService>();
              final place = Place(
                name: nameController.text.trim(),
                latitude: point.latitude,
                longitude: point.longitude,
              );
              await db.savePlace(place);
              if (context.mounted) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Added "${place.name}"')),
                );
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showPlaceDetails(Place place) {
    showModalBottomSheet(
      context: context,
      builder: (context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(place.name, style: Theme.of(context).textTheme.headlineSmall),
            if (place.address != null) Text(place.address!),
            if (place.description != null) ...[
              const SizedBox(height: 8),
              Text(place.description!),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _deletePlace(place);
                  },
                  child:
                      const Text('Delete', style: TextStyle(color: Colors.red)),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _addPlace() {
    _showAddPlaceDialog();
  }

  void _addPlaceAtLocation(LatLng point) {
    _showAddPlaceDialog(lat: point.latitude, lng: point.longitude);
  }

  void _showAddPlaceDialog({double? lat, double? lng}) {
    final nameController = TextEditingController();
    final addressController = TextEditingController();
    final latController = TextEditingController(text: lat?.toString() ?? '');
    final lngController = TextEditingController(text: lng?.toString() ?? '');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Place'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Name *')),
              const SizedBox(height: 8),
              TextField(
                  controller: addressController,
                  decoration: const InputDecoration(labelText: 'Address')),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                      child: TextField(
                          controller: latController,
                          decoration:
                              const InputDecoration(labelText: 'Latitude'),
                          keyboardType: TextInputType.number)),
                  const SizedBox(width: 8),
                  Expanded(
                      child: TextField(
                          controller: lngController,
                          decoration:
                              const InputDecoration(labelText: 'Longitude'),
                          keyboardType: TextInputType.number)),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              if (nameController.text.trim().isEmpty) return;
              final db = context.read<DatabaseService>();
              final place = Place(
                name: nameController.text.trim(),
                latitude: double.tryParse(latController.text) ?? 0,
                longitude: double.tryParse(lngController.text) ?? 0,
                address: addressController.text.trim().isEmpty
                    ? null
                    : addressController.text.trim(),
              );
              await db.savePlace(place);
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  void _deletePlace(Place place) async {
    final db = context.read<DatabaseService>();
    await db.deletePlace(place.id);
  }
}
