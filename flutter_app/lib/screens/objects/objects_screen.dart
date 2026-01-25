import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/models.dart';
import '../../services/database_service.dart';

class ObjectsScreen extends StatefulWidget {
  const ObjectsScreen({super.key});

  @override
  State<ObjectsScreen> createState() => _ObjectsScreenState();
}

class _ObjectsScreenState extends State<ObjectsScreen> {
  @override
  Widget build(BuildContext context) {
    return Consumer<DatabaseService>(
      builder: (context, db, _) {
        return FutureBuilder<List<EventObject>>(
          future: db.getObjects(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            final objects = snapshot.data ?? [];

            return Scaffold(
              body: objects.isEmpty
                  ? _buildEmptyState()
                  : ListView.builder(
                      itemCount: objects.length,
                      padding: const EdgeInsets.only(bottom: 80),
                      itemBuilder: (context, index) {
                        final object = objects[index];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .secondaryContainer,
                            child: const Icon(Icons.category),
                          ),
                          title: Text(object.name),
                          subtitle: object.description != null
                              ? Text(object.description!)
                              : null,
                          trailing: object.eventIds.isNotEmpty
                              ? Chip(
                                  label:
                                      Text('${object.eventIds.length} events'))
                              : null,
                          onTap: () => _showObjectDetails(context, db, object),
                        );
                      },
                    ),
              floatingActionButton: FloatingActionButton.extended(
                onPressed: () => _addObject(context),
                icon: const Icon(Icons.add),
                label: const Text('Add Object'),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.category_outlined, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text('No objects yet',
              style: TextStyle(fontSize: 18, color: Colors.grey[600])),
          const SizedBox(height: 8),
          Text('Objects are things involved in events',
              style: TextStyle(color: Colors.grey[500])),
        ],
      ),
    );
  }

  void _addObject(BuildContext context) {
    final nameController = TextEditingController();
    final descController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Object'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Name *')),
            const SizedBox(height: 8),
            TextField(
                controller: descController,
                decoration: const InputDecoration(labelText: 'Description'),
                maxLines: 2),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              if (nameController.text.trim().isEmpty) return;
              final db = context.read<DatabaseService>();
              final object = EventObject(
                name: nameController.text.trim(),
                description: descController.text.trim().isEmpty
                    ? null
                    : descController.text.trim(),
              );
              await db.saveObject(object);
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  void _showObjectDetails(
      BuildContext context, DatabaseService db, EventObject object) {
    showModalBottomSheet(
      context: context,
      builder: (context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(object.name, style: Theme.of(context).textTheme.headlineSmall),
            if (object.description != null) ...[
              const SizedBox(height: 8),
              Text(object.description!),
            ],
            if (object.eventIds.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Involved in ${object.eventIds.length} events'),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () async {
                    await db.deleteObject(object.id);
                    if (context.mounted) Navigator.pop(context);
                  },
                  child:
                      const Text('Delete', style: TextStyle(color: Colors.red)),
                ),
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
