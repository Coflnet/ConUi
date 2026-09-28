import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../models/models.dart';
import '../../services/database_service.dart';
import 'place_sheet.dart';

/// The places list. The map (with its own "tap to add" and marker flow)
/// now lives in the dedicated Map tab - see [MapScreen] - so this screen
/// stays reachable as a plain, searchable-by-scrolling list rather than
/// duplicating a second map here.
class PlacesScreen extends StatefulWidget {
  const PlacesScreen({super.key});

  @override
  State<PlacesScreen> createState() => _PlacesScreenState();
}

class _PlacesScreenState extends State<PlacesScreen> {
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

            final l10n = AppLocalizations.of(context);
            final places = snapshot.data ?? [];
            return Scaffold(
              body: places.isEmpty ? _buildEmptyState(l10n) : _buildListView(places),
              floatingActionButton: FloatingActionButton.extended(
                onPressed: () => _showAddPlaceDialog(),
                icon: const Icon(Icons.add),
                label: Text(l10n.placesAdd),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildEmptyState(AppLocalizations l10n) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.place_outlined, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(l10n.placesEmptyTitle, style: TextStyle(fontSize: 18, color: Colors.grey[600])),
          const SizedBox(height: 8),
          Text(l10n.placesEmptySubtitle,
              style: TextStyle(color: Colors.grey[500])),
        ],
      ),
    );
  }

  Widget _buildListView(List<Place> places) {
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
          trailing: place.category != null ? Chip(label: Text(place.category!)) : null,
          onTap: () => PlaceSheet.show(context, placeId: place.id),
        );
      },
    );
  }

  void _showAddPlaceDialog() {
    final l10n = AppLocalizations.of(context);
    final nameController = TextEditingController();
    final addressController = TextEditingController();
    final latController = TextEditingController();
    final lngController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.placesAdd),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: nameController,
                  decoration: InputDecoration(labelText: l10n.placesNameLabel)),
              const SizedBox(height: 8),
              TextField(
                  controller: addressController,
                  decoration: InputDecoration(labelText: l10n.placesAddressLabel)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                      child: TextField(
                          controller: latController,
                          decoration: InputDecoration(labelText: l10n.placesLatitudeLabel),
                          keyboardType: TextInputType.number)),
                  const SizedBox(width: 8),
                  Expanded(
                      child: TextField(
                          controller: lngController,
                          decoration: InputDecoration(labelText: l10n.placesLongitudeLabel),
                          keyboardType: TextInputType.number)),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.commonCancel)),
          TextButton(
            onPressed: () async {
              if (nameController.text.trim().isEmpty) return;
              final db = context.read<DatabaseService>();
              final place = Place(
                name: nameController.text.trim(),
                latitude: double.tryParse(latController.text) ?? 0,
                longitude: double.tryParse(lngController.text) ?? 0,
                address:
                    addressController.text.trim().isEmpty ? null : addressController.text.trim(),
              );
              await db.savePlace(place);
              if (context.mounted) Navigator.pop(context);
            },
            child: Text(l10n.commonAdd),
          ),
        ],
      ),
    );
  }
}
