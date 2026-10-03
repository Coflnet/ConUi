import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/gen/app_localizations.dart';
import '../services/database_service.dart';
import '../services/sync_service.dart';
import 'persons/persons_screen.dart';
import 'events/events_screen.dart';
import 'map/map_screen.dart';
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
    const MapScreen(),
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

  // Shared between the bottom NavigationBar (narrow) and the side
  // NavigationRail (wide, see build()) so the five destinations' icons are
  // declared exactly once. Labels come from [_navLabel] (localized), in the
  // same order.
  static const _destinationIcons = [
    (icon: Icons.map_outlined, selected: Icons.map),
    (icon: Icons.people_outline, selected: Icons.people),
    (icon: Icons.event_outlined, selected: Icons.event),
    (icon: Icons.place_outlined, selected: Icons.place),
    (icon: Icons.category_outlined, selected: Icons.category),
  ];

  String _navLabel(AppLocalizations l10n, int index) {
    switch (index) {
      case 0:
        return l10n.homeNavMap;
      case 1:
        return l10n.homeNavPeople;
      case 2:
        return l10n.homeNavStories;
      case 3:
        return l10n.homeNavPlaces;
      default:
        return l10n.homeNavObjects;
    }
  }

  // About a tablet/small-desktop width: wide enough that a 5-item bottom
  // bar would spread its labels thin, per the brief.
  static const _wideLayoutBreakpoint = 840.0;

  void _onDestinationSelected(int index) {
    setState(() {
      _selectedIndex = index;
      if (_isSearching) {
        _isSearching = false;
        _searchController.clear();
        _searchQuery = '';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isWide = MediaQuery.sizeOf(context).width >= _wideLayoutBreakpoint;
    final bodyContent = _isSearching && _searchQuery.isNotEmpty
        ? _buildSearchResults(l10n)
        : IndexedStack(
            index: _selectedIndex,
            children: [
              for (final (index, screen) in _screens.indexed)
                HeroMode(enabled: index == _selectedIndex, child: screen),
            ],
          );

    return Scaffold(
      appBar: AppBar(
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: l10n.homeSearchHint,
                  border: InputBorder.none,
                ),
                onChanged: (value) => setState(() => _searchQuery = value),
              )
            : Text(_getTitle(l10n)),
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
            tooltip: _isSearching ? l10n.homeSearchClose : l10n.homeSearchOpen,
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
                      SnackBar(
                          content: Text(syncService.needsSignIn
                              ? l10n.homeSyncSignInRequired
                              : syncService.needsEncryptionPassword
                                  ? l10n.homeSyncPasswordRequired
                                  : syncService.lastError != null
                                      ? l10n.settingsSyncFailed(
                                          syncService.lastError!)
                                      : l10n.homeSyncComplete)),
                    );
                  }
                },
                tooltip: l10n.homeSyncNow,
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
      body: isWide
          ? Row(
              children: [
                NavigationRail(
                  selectedIndex: _selectedIndex,
                  onDestinationSelected: _onDestinationSelected,
                  labelType: NavigationRailLabelType.all,
                  destinations: [
                    for (final (index, d) in _destinationIcons.indexed)
                      NavigationRailDestination(
                        icon: Icon(d.icon),
                        selectedIcon: Icon(d.selected),
                        label: Text(_navLabel(l10n, index)),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: bodyContent),
              ],
            )
          : bodyContent,
      bottomNavigationBar: isWide
          ? null
          : NavigationBar(
              selectedIndex: _selectedIndex,
              onDestinationSelected: _onDestinationSelected,
              destinations: [
                for (final (index, d) in _destinationIcons.indexed)
                  NavigationDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selected),
                    label: _navLabel(l10n, index),
                  ),
              ],
            ),
    );
  }

  Widget _buildSearchResults(AppLocalizations l10n) {
    final db = context.read<DatabaseService>();
    return FutureBuilder<List<SearchResult>>(
      future: _performSearch(db, _searchQuery, l10n),
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
                Text(l10n.homeNoResultsFor(_searchQuery),
                    style: TextStyle(color: Colors.grey[600], fontSize: 16)),
              ],
            ),
          );
        }
        return ListView.builder(
          itemCount: results.length,
          itemBuilder: (context, index) {
            final result = results[index];
            return _buildSearchResultTile(l10n, result);
          },
        );
      },
    );
  }

  Future<List<SearchResult>> _performSearch(
      DatabaseService db, String query, AppLocalizations l10n) async {
    final results = <SearchResult>[];
    final lowerQuery = query.toLowerCase();
    final locale = Localizations.localeOf(context).toString();

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
                  ? l10n.homeAka(person.aliases.first)
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
              '${eventTypeLabel(l10n, event.type)} • ${event.displayDate(locale)}',
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

  Widget _buildSearchResultTile(AppLocalizations l10n, SearchResult result) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: _getColorForType(result.type),
        child: Icon(result.icon, color: Colors.white, size: 20),
      ),
      title: Text(result.title),
      subtitle: result.subtitle != null ? Text(result.subtitle!) : null,
      trailing: Chip(
        label: Text(_resultTypeLabel(l10n, result.type)),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
      ),
      onTap: () => _navigateToResult(result),
    );
  }

  String _resultTypeLabel(AppLocalizations l10n, SearchResultType type) {
    switch (type) {
      case SearchResultType.person:
        return l10n.homeResultTypePerson;
      case SearchResultType.event:
        return l10n.homeResultTypeStory;
      case SearchResultType.object:
        return l10n.homeResultTypeObject;
      case SearchResultType.place:
        return l10n.homeResultTypePlace;
    }
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
        setState(() => _selectedIndex = 1);
        Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => PersonDetailScreen(personId: result.id)),
        );
        break;
      case SearchResultType.event:
        setState(() => _selectedIndex = 2);
        Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => EventDetailScreen(eventId: result.id)),
        );
        break;
      case SearchResultType.object:
        setState(() => _selectedIndex = 4);
        break;
      case SearchResultType.place:
        setState(() => _selectedIndex = 3);
        break;
    }
  }

  String _getTitle(AppLocalizations l10n) {
    if (_selectedIndex >= 0 && _selectedIndex < _destinationIcons.length) {
      return _navLabel(l10n, _selectedIndex);
    }
    return l10n.appTitle;
  }
}
