import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../models/models.dart';
import '../../services/database_service.dart';
import '../../services/interaction_feedback.dart';
import 'place_sheet.dart';
import '../map/location_picker_screen.dart';
import '../map/nearby_place.dart';

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
            if (snapshot.hasError) {
              return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(l10n.savedDataLoadFailed, textAlign: TextAlign.center),
                TextButton(onPressed: () => setState(() {}), child: Text(l10n.commonRetry)),
              ]));
            }
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
      padding: const EdgeInsets.only(bottom: 88),
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

  Future<void> _showAddPlaceDialog() async {
    final l10n = AppLocalizations.of(context);
    final db = context.read<DatabaseService>();
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final initialPosition = LatLng(prefs.getDouble('places_map_lat') ?? 50,
        prefs.getDouble('places_map_lng') ?? 10);
    final nameController = TextEditingController();
    final addressController = TextEditingController();
    LatLng? position;
    Future<String>? suggestedName;
    String? error;
    bool saving = false;

    final route = DialogRoute<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(builder: (context, update) => PopScope(
        canPop: !saving,
        child: AlertDialog(
          title: Text(l10n.placesAdd),
          content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            FutureBuilder<String>(
              future: suggestedName,
              builder: (context, snapshot) => TextField(
                controller: nameController,
                enabled: !saving,
                decoration: InputDecoration(labelText: l10n.placesOptionalNameLabel,
                    hintText: snapshot.data ?? l10n.quickAddPlaceNameHint),
              ),
            ),
            const SizedBox(height: 8),
            TextField(controller: addressController, enabled: !saving,
                decoration: InputDecoration(labelText: l10n.placesAddressLabel)),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: saving ? null : () async {
                final selected = await Navigator.push<LatLng>(context, MaterialPageRoute(
                  builder: (_) => LocationPickerScreen(
                    initialPosition: position ?? initialPosition,
                    initialZoom: position == null ? prefs.getDouble('places_map_zoom') ?? 5 : 15,
                  ),
                ));
                if (selected == null || !context.mounted) return;
                update(() {
                  position = selected;
                  suggestedName = resolveDefaultPlaceName(selected, l10n);
                  error = null;
                });
              },
              icon: const Icon(Icons.map_outlined),
              label: Text(position == null ? l10n.locationPickerTitle : l10n.quickAddChangePosition),
            ),
            if (position != null) Text(
              '${position!.latitude.toStringAsFixed(5)}, ${position!.longitude.toStringAsFixed(5)}'),
            if (error != null) Padding(padding: const EdgeInsets.only(top: 8),
                child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          ])),
          actions: [
            TextButton(onPressed: saving ? null : () => Navigator.pop(context),
                child: Text(l10n.commonCancel)),
            TextButton(
              onPressed: saving ? null : () async {
                if (position == null) {
                  update(() => error = l10n.placesLocationRequired);
                  return;
                }
                update(() { saving = true; error = null; });
                try {
                  final name = nameController.text.trim().isNotEmpty
                      ? nameController.text.trim() : await suggestedName!;
                  final place = Place(name: name, latitude: position!.latitude,
                    longitude: position!.longitude,
                    address: addressController.text.trim().isEmpty ? null : addressController.text.trim());
                  await db.savePlace(place);
                  if (context.mounted) {
                    context.read<InteractionFeedback?>()?.play(FeedbackCue.success);
                    Navigator.pop(context);
                  }
                } catch (_) {
                  if (context.mounted) update(() { saving = false; error = l10n.placesSaveFailed; });
                }
              },
              child: saving ? const SizedBox(width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)) : Text(l10n.commonAdd),
            ),
          ],
        ),
      )),
    );
    await Navigator.of(context, rootNavigator: true).push(route);
    await route.completed;
    nameController.dispose();
    addressController.dispose();
  }
}
