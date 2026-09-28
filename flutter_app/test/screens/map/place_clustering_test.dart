import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/models/models.dart';
import 'package:relationship_manager/screens/map/place_clustering.dart';

Place _place(String id, double lat, double lng) =>
    Place(id: id, name: id, latitude: lat, longitude: lng);

void main() {
  group('groupPlacesForZoom', () {
    test('empty input yields no groups', () {
      expect(groupPlacesForZoom([], {}, 5), isEmpty);
    });

    test('at a high zoom every place gets its own group', () {
      final places = [_place('a', 48.85, 2.35), _place('b', 48.86, 2.36)];
      final groups = groupPlacesForZoom(places, {}, 16);

      expect(groups, hasLength(2));
      expect(groups.every((g) => !g.isCluster), isTrue);
    });

    test('at a low zoom, nearby places are grouped into one cluster', () {
      // A few meters apart - well within even the smallest grid cell.
      final places = [
        _place('a', 48.8566, 2.3522),
        _place('b', 48.8567, 2.3523),
      ];
      final groups = groupPlacesForZoom(places, {}, 3);

      expect(groups, hasLength(1));
      expect(groups.single.isCluster, isTrue);
      expect(groups.single.places, hasLength(2));
    });

    test('far apart places stay in separate groups even at a low zoom', () {
      final places = [_place('paris', 48.8566, 2.3522), _place('tokyo', 35.6762, 139.6503)];
      final groups = groupPlacesForZoom(places, {}, 2);

      expect(groups, hasLength(2));
    });

    test('a cluster sums the story counts of every place it contains', () {
      final places = [
        _place('a', 48.8566, 2.3522),
        _place('b', 48.8567, 2.3523),
      ];
      final counts = {'a': 3, 'b': 2};
      final groups = groupPlacesForZoom(places, counts, 3);

      expect(groups.single.storyCount, 5);
    });

    test('an individual (non-clustered) group reports just that place\'s story count', () {
      final places = [_place('a', 48.85, 2.35)];
      final groups = groupPlacesForZoom(places, {'a': 4}, 16);

      expect(groups.single.storyCount, 4);
      expect(groups.single.places.single.id, 'a');
    });

    test('a place missing from the story-count map defaults to zero', () {
      final places = [_place('a', 48.85, 2.35)];
      final groups = groupPlacesForZoom(places, {}, 16);

      expect(groups.single.storyCount, 0);
    });

    test('cluster position is the average of its places\' coordinates', () {
      final places = [_place('a', 10.0, 10.0), _place('b', 10.0, 10.002)];
      final groups = groupPlacesForZoom(places, {}, 3);

      expect(groups.single.position.latitude, closeTo(10.0, 1e-9));
      expect(groups.single.position.longitude, closeTo(10.001, 1e-9));
    });
  });
}
