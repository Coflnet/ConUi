import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../models/models.dart';
import '../../services/database_service.dart';
import 'add_event_screen.dart';
import 'event_detail_screen.dart';

class EventsScreen extends StatefulWidget {
  const EventsScreen({super.key});

  @override
  State<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends State<EventsScreen> {
  DateTime _selectedMonth = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final monthKey =
        '${_selectedMonth.year}-${_selectedMonth.month.toString().padLeft(2, '0')}';

    return Consumer<DatabaseService>(
      builder: (context, db, _) {
        return Scaffold(
          body: Column(
            children: [
              _buildMonthSelector(),
              Expanded(
                child: FutureBuilder<List<Event>>(
                  future: db.getEvents(monthKey: monthKey),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    final events = snapshot.data ?? [];
                    events.sort((a, b) => b.dateTime.compareTo(a.dateTime));

                    if (events.isEmpty) {
                      return _buildEmptyState();
                    }

                    return ListView.builder(
                      itemCount:
                          events.length + 1, // +1 for the Add button at the end
                      padding: const EdgeInsets.only(bottom: 80),
                      itemBuilder: (context, index) {
                        if (index == events.length) {
                          // Add Event button at the end of the list
                          return Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: OutlinedButton.icon(
                              onPressed: _addEvent,
                              icon: const Icon(Icons.add),
                              label: const Text('Add Another Event'),
                            ),
                          );
                        }
                        final event = events[index];
                        return _EventListTile(
                          event: event,
                          onTap: () => _openEventDetail(event),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _addEvent,
            icon: const Icon(Icons.add),
            label: const Text('Add Event'),
          ),
        );
      },
    );
  }

  Widget _buildMonthSelector() {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () {
              setState(() {
                _selectedMonth = DateTime(
                  _selectedMonth.year,
                  _selectedMonth.month - 1,
                );
              });
            },
          ),
          Text(
            DateFormat.yMMMM().format(_selectedMonth),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: () {
              setState(() {
                _selectedMonth = DateTime(
                  _selectedMonth.year,
                  _selectedMonth.month + 1,
                );
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.event_outlined, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            'No events this month',
            style: TextStyle(fontSize: 18, color: Colors.grey[600]),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _addEvent,
            icon: const Icon(Icons.add),
            label: const Text('Add Event'),
          ),
        ],
      ),
    );
  }

  void _openEventDetail(Event event) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EventDetailScreen(eventId: event.id),
      ),
    );
  }

  void _addEvent() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const AddEventScreen(),
      ),
    );
  }
}

class _EventListTile extends StatelessWidget {
  final Event event;
  final VoidCallback onTap;

  const _EventListTile({required this.event, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: _getEventColor(event.type),
          child: Icon(_getEventIcon(event.type), color: Colors.white, size: 20),
        ),
        title: Text(event.title),
        subtitle: Text(
          '${DateFormat.MMMd().format(event.dateTime)} • ${event.type.name}',
        ),
        trailing: event.participantIds.isNotEmpty
            ? Chip(
                label: Text('${event.participantIds.length}'),
                avatar: const Icon(Icons.people, size: 16),
              )
            : null,
        onTap: onTap,
      ),
    );
  }

  IconData _getEventIcon(EventType type) {
    switch (type) {
      case EventType.meeting:
        return Icons.groups;
      case EventType.call:
        return Icons.phone;
      case EventType.message:
        return Icons.chat;
      case EventType.visit:
        return Icons.home;
      case EventType.trip:
        return Icons.flight;
      case EventType.celebration:
        return Icons.celebration;
      case EventType.work:
        return Icons.work;
      case EventType.social:
        return Icons.people;
      case EventType.other:
        return Icons.event;
    }
  }

  Color _getEventColor(EventType type) {
    switch (type) {
      case EventType.meeting:
        return Colors.blue;
      case EventType.call:
        return Colors.green;
      case EventType.message:
        return Colors.purple;
      case EventType.visit:
        return Colors.orange;
      case EventType.trip:
        return Colors.cyan;
      case EventType.celebration:
        return Colors.pink;
      case EventType.work:
        return Colors.brown;
      case EventType.social:
        return Colors.teal;
      case EventType.other:
        return Colors.grey;
    }
  }
}
