import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/database_service.dart';
import '../services/sync_service.dart';
import 'persons/persons_screen.dart';
import 'events/events_screen.dart';
import 'places/places_screen.dart';
import 'objects/objects_screen.dart';
import 'settings_screen.dart';
import 'persons/person_detail_screen.dart';
import 'events/event_detail_screen.dart';

enum SearchResultType { person, event, object, place }

class SearchResult {
  final SearchResultType type;
  final String id;
  final String title;
  final String? subtitle;
  final IconData icon;

  SearchResult({
    required this.type,
    required this.id,
    required this.title,
    this.subtitle,
    required this.icon,
  });
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _selectedIndex = 0;
  bool _isSearching = false;
  final _searchController = TextEditingController();
  String _searchQuery = '';

  final List<Widget> _screens = [
    const PersonsScreen(),
    const EventsScreen(),
    const PlacesScreen(),
    const ObjectsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Delay sync to after the first frame to avoid calling notifyListeners during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncOnStart();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final syncService = context.read<SyncService>();

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // Sync when app goes to background or closes
      syncService.syncOnClose();
    } else if (state == AppLifecycleState.resumed) {
      // Sync when app comes back to foreground
      syncService.syncOnOpen();
    }
  }

  Future<void> _syncOnStart() async {
    final syncService = context.read<SyncService>();
    await syncService.syncOnOpen();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search people, events, objects...',
                  border: InputBorder.none,
                ),
                onChanged: (value) => setState(() => _searchQuery = value),
              )
            : Text(_getTitle()),
        actions: [
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                _isSearching = !_isSearching;
                if (!_isSearching) {
                  _searchController.clear();
                  _searchQuery = '';
                }
              });
            },
            tooltip: _isSearching ? 'Close search' : 'Search',
          ),
          Consumer<SyncService>(
            builder: (context, syncService, _) {
              if (syncService.isSyncing) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                );
              }
              return IconButton(
                icon: const Icon(Icons.sync),
                onPressed: () async {
                  await syncService.forceFullSync();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Sync complete')),
                    );
                  }
                },
                tooltip: 'Sync now',
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
          ),
        ],
      ),
      body: _isSearching && _searchQuery.isNotEmpty
          ? _buildSearchResults()
          : IndexedStack(
              index: _selectedIndex,
              children: _screens,
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() {
            _selectedIndex = index;
            if (_isSearching) {
              _isSearching = false;
              _searchController.clear();
              _searchQuery = '';
            }
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: 'People',
          ),
          NavigationDestination(
            icon: Icon(Icons.event_outlined),
            selectedIcon: Icon(Icons.event),
            label: 'Events',
          ),
          NavigationDestination(
            icon: Icon(Icons.place_outlined),
            selectedIcon: Icon(Icons.place),
            label: 'Places',
          ),
          NavigationDestination(
            icon: Icon(Icons.category_outlined),
            selectedIcon: Icon(Icons.category),
            label: 'Objects',
          ),
        ],
      ),
    );
  }

  Widget _buildSearchResults() {
    final db = context.read<DatabaseService>();
    return FutureBuilder<List<SearchResult>>(
      future: _performSearch(db, _searchQuery),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final results = snapshot.data ?? [];
        if (results.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.search_off, size: 64, color: Colors.grey[400]),
                const SizedBox(height: 16),
                Text('No results for "$_searchQuery"',
                    style: TextStyle(color: Colors.grey[600], fontSize: 16)),
              ],
            ),
          );
        }
        return ListView.builder(
          itemCount: results.length,
          itemBuilder: (context, index) {
            final result = results[index];
            return _buildSearchResultTile(result);
          },
        );
      },
    );
  }

  Future<List<SearchResult>> _performSearch(
      DatabaseService db, String query) async {
    final results = <SearchResult>[];
    final lowerQuery = query.toLowerCase();

    // Search persons
    final persons = await db.getPersons();
    for (final person in persons) {
      if (person.name.toLowerCase().contains(lowerQuery) ||
          person.aliases.any((a) => a.toLowerCase().contains(lowerQuery)) ||
          (person.email?.toLowerCase().contains(lowerQuery) ?? false)) {
        results.add(SearchResult(
          type: SearchResultType.person,
          id: person.id,
          title: person.name,
          subtitle: person.email ??
              (person.aliases.isNotEmpty
                  ? 'aka ${person.aliases.first}'
                  : null),
          icon: Icons.person,
        ));
      }
    }

    // Search events
    final events = await db.getEvents();
    for (final event in events) {
      if (event.title.toLowerCase().contains(lowerQuery) ||
          (event.description?.toLowerCase().contains(lowerQuery) ?? false)) {
        results.add(SearchResult(
          type: SearchResultType.event,
          id: event.id,
          title: event.title,
          subtitle:
              '${event.type.name} • ${event.dateTime.toString().split(' ')[0]}',
          icon: Icons.event,
        ));
      }
    }

    // Search objects
    final objects = await db.getObjects();
    for (final object in objects) {
      if (object.name.toLowerCase().contains(lowerQuery) ||
          (object.description?.toLowerCase().contains(lowerQuery) ?? false)) {
        results.add(SearchResult(
          type: SearchResultType.object,
          id: object.id,
          title: object.name,
          subtitle: object.description,
          icon: Icons.category,
        ));
      }
    }

    // Search places
    final places = await db.getPlaces();
    for (final place in places) {
      if (place.name.toLowerCase().contains(lowerQuery) ||
          (place.address?.toLowerCase().contains(lowerQuery) ?? false)) {
        results.add(SearchResult(
          type: SearchResultType.place,
          id: place.id,
          title: place.name,
          subtitle: place.address,
          icon: Icons.place,
        ));
      }
    }

    return results;
  }

  Widget _buildSearchResultTile(SearchResult result) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: _getColorForType(result.type),
        child: Icon(result.icon, color: Colors.white, size: 20),
      ),
      title: Text(result.title),
      subtitle: result.subtitle != null ? Text(result.subtitle!) : null,
      trailing: Chip(
        label: Text(result.type.name),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
      ),
      onTap: () => _navigateToResult(result),
    );
  }

  Color _getColorForType(SearchResultType type) {
    switch (type) {
      case SearchResultType.person:
        return Colors.blue;
      case SearchResultType.event:
        return Colors.orange;
      case SearchResultType.object:
        return Colors.purple;
      case SearchResultType.place:
        return Colors.green;
    }
  }

  void _navigateToResult(SearchResult result) {
    setState(() {
      _isSearching = false;
      _searchController.clear();
      _searchQuery = '';
    });

    switch (result.type) {
      case SearchResultType.person:
        setState(() => _selectedIndex = 0);
        Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => PersonDetailScreen(personId: result.id)),
        );
        break;
      case SearchResultType.event:
        setState(() => _selectedIndex = 1);
        Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => EventDetailScreen(eventId: result.id)),
        );
        break;
      case SearchResultType.object:
        setState(() => _selectedIndex = 3);
        break;
      case SearchResultType.place:
        setState(() => _selectedIndex = 2);
        break;
    }
  }

  String _getTitle() {
    switch (_selectedIndex) {
      case 0:
        return 'People';
      case 1:
        return 'Events';
      case 2:
        return 'Places';
      case 3:
        return 'Objects';
      default:
        return 'Relationship Manager';
    }
  }
}
