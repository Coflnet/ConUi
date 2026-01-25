import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/models.dart';
import '../../services/database_service.dart';
import 'person_detail_screen.dart';
import 'add_person_screen.dart';

class PersonsScreen extends StatefulWidget {
  const PersonsScreen({super.key});

  @override
  State<PersonsScreen> createState() => _PersonsScreenState();
}

class _PersonsScreenState extends State<PersonsScreen> {
  final _searchController = TextEditingController();
  String _searchQuery = '';
  List<Person> _allPersons = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadPersons();
    _searchController.addListener(() {
      if (_searchQuery != _searchController.text) {
        setState(() {
          _searchQuery = _searchController.text;
        });
      }
    });
  }

  Future<void> _loadPersons() async {
    setState(() => _isLoading = true);
    final db = context.read<DatabaseService>();
    final persons = await db.getPersons();
    if (mounted) {
      setState(() {
        _allPersons = persons;
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Filter persons based on search query
    final filteredPersons = _searchQuery.isEmpty
        ? _allPersons
        : _allPersons
            .where((p) =>
                p.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
                p.aliases.any((a) =>
                    a.toLowerCase().contains(_searchQuery.toLowerCase())) ||
                (p.email?.toLowerCase().contains(_searchQuery.toLowerCase()) ??
                    false))
            .toList();

    filteredPersons.sort((a, b) => a.name.compareTo(b.name));

    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search people...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                        },
                      )
                    : null,
              ),
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : filteredPersons.isEmpty
                    ? _buildEmptyState()
                    : RefreshIndicator(
                        onRefresh: _loadPersons,
                        child: ListView.builder(
                          itemCount:
                              filteredPersons.length + 1, // +1 for Add button
                          padding: const EdgeInsets.only(bottom: 80),
                          itemBuilder: (context, index) {
                            if (index == filteredPersons.length) {
                              return Padding(
                                padding: const EdgeInsets.all(16.0),
                                child: OutlinedButton.icon(
                                  onPressed: _addPerson,
                                  icon: const Icon(Icons.person_add),
                                  label: const Text('Add Person'),
                                ),
                              );
                            }
                            final person = filteredPersons[index];
                            return _PersonListTile(
                              person: person,
                              onTap: () => _openPersonDetail(person),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addPerson,
        icon: const Icon(Icons.add),
        label: const Text('Add Person'),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.people_outline,
            size: 64,
            color: Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            _searchQuery.isEmpty
                ? 'No people yet'
                : 'No people match your search',
            style: TextStyle(
              fontSize: 18,
              color: Colors.grey[600],
            ),
          ),
          if (_searchQuery.isEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Add your first contact to get started',
              style: TextStyle(color: Colors.grey[500]),
            ),
          ],
        ],
      ),
    );
  }

  void _openPersonDetail(Person person) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PersonDetailScreen(personId: person.id),
      ),
    );
    _loadPersons();
  }

  void _addPerson() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const AddPersonScreen(),
      ),
    );
    _loadPersons();
  }
}

class _PersonListTile extends StatelessWidget {
  final Person person;
  final VoidCallback onTap;

  const _PersonListTile({
    required this.person,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        child: Text(
          person.name.isNotEmpty ? person.name[0].toUpperCase() : '?',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onPrimaryContainer,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      title: Text(person.name),
      subtitle: Text(
        [
          if (person.aliases.isNotEmpty) 'aka ${person.aliases.first}',
          if (person.company != null) person.company,
          if (person.email != null) person.email,
        ].where((e) => e != null).take(2).join(' • '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

// Floating action button for adding people
class PersonsScreenFAB extends StatelessWidget {
  const PersonsScreenFAB({super.key});

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton(
      onPressed: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const AddPersonScreen(),
          ),
        );
      },
      child: const Icon(Icons.add),
    );
  }
}
