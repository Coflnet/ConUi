import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../relationships/family_graph.dart';
import '../../relationships/graph_layout.dart';
import '../../relationships/relationship_text.dart';
import '../../services/database_service.dart';
import 'add_connection_dialog.dart';
import 'person_detail_screen.dart';

const double _nodeWidth = 132;
const double _nodeHeight = 60;
const double _canvasPadding = 60;
const int _defaultNodeLimit = 200;

/// Explores the family graph starting from any person, in every direction - not a tree
/// rooted in one fixed person. Pan/zoom via [InteractiveViewer]; tapping a node offers
/// to re-center the graph there (re-running the layout with that person in the
/// middle), open their page, or add a relationship from them. A depth control (1-4
/// hops) and a node limit keep large graphs (several hundred persons) from freezing
/// the screen; a text alternative lists the same relationships as sentences.
class RelationshipGraphScreen extends StatefulWidget {
  final String centerPersonId;

  const RelationshipGraphScreen({super.key, required this.centerPersonId});

  @override
  State<RelationshipGraphScreen> createState() => _RelationshipGraphScreenState();
}

class _RelationshipGraphScreenState extends State<RelationshipGraphScreen> {
  late String _centerPersonId;
  int _depth = 2;
  bool _showTextAlternative = false;
  int _refreshKey = 0;

  @override
  void initState() {
    super.initState();
    _centerPersonId = widget.centerPersonId;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<DatabaseService>(
      builder: (context, db, _) {
        return FutureBuilder<List<Object>>(
          key: ValueKey(_refreshKey),
          future: Future.wait([db.getPersons(), db.getConnections()]),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return Scaffold(
                appBar: AppBar(title: const Text('Family Graph')),
                body: const Center(child: CircularProgressIndicator()),
              );
            }

            final allPersons = snapshot.data![0] as List<Person>;
            final allConnections = snapshot.data![1] as List<Connection>;
            final graph = FamilyGraph.build(persons: allPersons, connections: allConnections);
            final centerPerson = graph.personById(_centerPersonId);

            if (centerPerson == null) {
              return Scaffold(
                appBar: AppBar(title: const Text('Family Graph')),
                body: const Center(child: Text('Person not found')),
              );
            }

            final traversal =
                graph.traverse(_centerPersonId, depth: _depth, nodeLimit: _defaultNodeLimit);
            final layout = computeGraphLayout(
              personIds: traversal.personIds,
              edges: traversal.edges,
              centerPersonId: _centerPersonId,
            );

            return Scaffold(
              appBar: AppBar(
                title: Text("${centerPerson.name}'s family graph"),
                actions: [
                  IconButton(
                    icon: Icon(_showTextAlternative ? Icons.account_tree_outlined : Icons.list_alt),
                    tooltip: _showTextAlternative ? 'Show graph' : 'Show as list',
                    onPressed: () => setState(() => _showTextAlternative = !_showTextAlternative),
                  ),
                ],
              ),
              body: Column(
                children: [
                  _buildDepthControl(),
                  if (traversal.truncated) _buildTruncatedBanner(context),
                  Expanded(
                    child: _showTextAlternative
                        ? _buildTextAlternative(graph, layout)
                        : _buildGraphView(context, db, graph, layout, allPersons, allConnections),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildDepthControl() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Text('Depth'),
          const SizedBox(width: 12),
          for (var d = 1; d <= 4; d++)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text('$d'),
                selected: _depth == d,
                onSelected: (_) => setState(() => _depth = d),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTruncatedBanner(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        'Showing the first $_defaultNodeLimit people reached - more exist. '
        'Reduce the depth or center on someone else to explore further.',
        style: TextStyle(color: scheme.onErrorContainer, fontSize: 12),
      ),
    );
  }

  Widget _buildGraphView(
    BuildContext context,
    DatabaseService db,
    FamilyGraph graph,
    GraphLayout layout,
    List<Person> allPersons,
    List<Connection> allConnections,
  ) {
    // traverse() always includes the centered person, so a lone person with no edges
    // still yields exactly one node - treat that the same as "nothing to show" too.
    if (layout.nodes.length <= 1) {
      return const Center(child: Text('No relationships to show yet.'));
    }

    final xs = layout.nodes.map((n) => n.x);
    final ys = layout.nodes.map((n) => n.y);
    final minX = xs.reduce(math.min);
    final minY = ys.reduce(math.min);
    final canvasWidth = xs.reduce(math.max) - minX + _nodeWidth + 2 * _canvasPadding;
    final canvasHeight = ys.reduce(math.max) - minY + _nodeHeight + 2 * _canvasPadding;

    Offset topLeftOf(GraphLayoutNode node) =>
        Offset(node.x - minX + _canvasPadding, node.y - minY + _canvasPadding);

    final centers = {
      for (final node in layout.nodes)
        node.id: topLeftOf(node) + const Offset(_nodeWidth / 2, _nodeHeight / 2),
    };

    final scheme = Theme.of(context).colorScheme;

    return InteractiveViewer(
      constrained: false,
      boundaryMargin: const EdgeInsets.all(300),
      minScale: 0.2,
      maxScale: 2.5,
      child: SizedBox(
        width: canvasWidth,
        height: canvasHeight,
        child: Stack(
          children: [
            CustomPaint(
              size: Size(canvasWidth, canvasHeight),
              painter: _GraphEdgePainter(
                edges: layout.edges,
                centers: centers,
                lineColor: scheme.outline,
                derivedColor: scheme.outlineVariant,
              ),
            ),
            for (final node in layout.nodes)
              Builder(builder: (context) {
                final topLeft = topLeftOf(node);
                return Positioned(
                  left: topLeft.dx,
                  top: topLeft.dy,
                  width: _nodeWidth,
                  height: _nodeHeight,
                  child: _NodeBubble(
                    person: graph.personById(node.id),
                    isCenter: node.id == _centerPersonId,
                    onTap: () => _showNodeActions(
                        context, db, graph, node.id, allPersons, allConnections),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildTextAlternative(FamilyGraph graph, GraphLayout layout) {
    if (layout.edges.isEmpty) {
      return const Center(child: Text('No relationships to show yet.'));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: layout.edges.length,
      itemBuilder: (context, index) {
        final edge = layout.edges[index];
        final sourceName = graph.personById(edge.sourceId)?.name ?? 'Unknown';
        final targetName = graph.personById(edge.targetId)?.name ?? 'Unknown';
        return ListTile(
          dense: true,
          leading: Icon(_iconFor(edge.kind)),
          title: Text(
            RelationshipText.graphEdgeSentence(sourceName, targetName, edge.kind, edge.isDerived),
          ),
        );
      },
    );
  }

  IconData _iconFor(GraphEdgeKind kind) {
    switch (kind) {
      case GraphEdgeKind.parentChild:
        return Icons.family_restroom;
      case GraphEdgeKind.partner:
        return Icons.favorite_border;
      case GraphEdgeKind.sibling:
        return Icons.people_outline;
      case GraphEdgeKind.other:
        return Icons.link;
    }
  }

  void _showNodeActions(
    BuildContext context,
    DatabaseService db,
    FamilyGraph graph,
    String personId,
    List<Person> allPersons,
    List<Connection> allConnections,
  ) {
    final person = graph.personById(personId);
    if (person == null) return;

    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(person.name, style: Theme.of(sheetContext).textTheme.titleMedium),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.center_focus_strong_outlined),
              title: const Text('Center graph on this person'),
              enabled: personId != _centerPersonId,
              onTap: () {
                Navigator.pop(sheetContext);
                setState(() => _centerPersonId = personId);
              },
            ),
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: const Text('Open person'),
              onTap: () {
                Navigator.pop(sheetContext);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => PersonDetailScreen(personId: personId)),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: Text('Add relationship from ${person.name}'),
              onTap: () async {
                Navigator.pop(sheetContext);
                final events = await db.getEvents();
                if (!context.mounted) return;
                final saved = await showAddConnectionDialog(
                  context,
                  viewedPerson: person,
                  allPersons: allPersons,
                  allConnections: allConnections,
                  allEvents: events,
                );
                if (saved == true && mounted) setState(() => _refreshKey++);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _NodeBubble extends StatelessWidget {
  final Person? person;
  final bool isCenter;
  final VoidCallback onTap;

  const _NodeBubble({required this.person, required this.isCenter, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = person?.name ?? 'Unknown';
    final foreground = isCenter ? scheme.onPrimaryContainer : scheme.onSurface;

    return Material(
      color: isCenter ? scheme.primaryContainer : scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isCenter ? BorderSide(color: scheme.primary, width: 2) : BorderSide.none,
      ),
      elevation: 2,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w600, color: foreground),
              ),
              if (person?.birthday != null)
                Text(
                  'b. ${person!.birthday!.year}',
                  style: TextStyle(fontSize: 11, color: foreground.withValues(alpha: 0.7)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Draws every [GraphLayoutEdge] between the given node centers. Line style encodes
/// [GraphEdgeKind]; a derived edge (see [GraphLayoutEdge.isDerived]) is always dashed,
/// regardless of kind, so it reads as "not an entered fact" at a glance.
class _GraphEdgePainter extends CustomPainter {
  final List<GraphLayoutEdge> edges;
  final Map<String, Offset> centers;
  final Color lineColor;
  final Color derivedColor;

  _GraphEdgePainter({
    required this.edges,
    required this.centers,
    required this.lineColor,
    required this.derivedColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final edge in edges) {
      final from = centers[edge.sourceId];
      final to = centers[edge.targetId];
      if (from == null || to == null) continue;

      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..color = edge.isDerived ? derivedColor : lineColor;

      if (edge.isDerived) {
        paint.strokeWidth = 1.5;
        _drawDashed(canvas, from, to, paint);
        continue;
      }

      switch (edge.kind) {
        case GraphEdgeKind.parentChild:
          paint.strokeWidth = 2;
          canvas.drawLine(from, to, paint);
          break;
        case GraphEdgeKind.partner:
          paint.strokeWidth = 3.5;
          canvas.drawLine(from, to, paint);
          break;
        case GraphEdgeKind.sibling:
          paint.strokeWidth = 1.5;
          _drawDotted(canvas, from, to, paint);
          break;
        case GraphEdgeKind.other:
          paint.strokeWidth = 1;
          paint.color = paint.color.withValues(alpha: 0.55);
          canvas.drawLine(from, to, paint);
          break;
      }
    }
  }

  void _drawDashed(Canvas canvas, Offset a, Offset b, Paint paint,
      {double dashLength = 8, double gapLength = 5}) {
    final total = (b - a).distance;
    if (total == 0) return;
    final direction = (b - a) / total;
    var drawn = 0.0;
    var drawing = true;
    while (drawn < total) {
      final segment = drawing ? dashLength : gapLength;
      final next = math.min(drawn + segment, total);
      if (drawing) canvas.drawLine(a + direction * drawn, a + direction * next, paint);
      drawn = next;
      drawing = !drawing;
    }
  }

  void _drawDotted(Canvas canvas, Offset a, Offset b, Paint paint, {double spacing = 6}) {
    final total = (b - a).distance;
    if (total == 0) return;
    final direction = (b - a) / total;
    final dotPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = paint.color;
    var d = 0.0;
    while (d < total) {
      canvas.drawCircle(a + direction * d, paint.strokeWidth, dotPaint);
      d += spacing;
    }
  }

  @override
  bool shouldRepaint(covariant _GraphEdgePainter oldDelegate) =>
      oldDelegate.edges != edges || oldDelegate.centers != centers;
}
