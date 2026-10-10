import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:sae/domain/logic/access.dart';
import 'package:sae/domain/logic/geo.dart';
import 'package:sae/domain/logic/time_keys.dart';

/// Mirrors `SAE-Dashboard/src/tests/geo.test.ts`.
///
/// These assertions are deliberately the *same* ones the dashboard runs. Both
/// sides compute a distance from the same stored coordinates, so if either
/// implementation drifts the other will disagree with it — and the dashboard
/// would then reject punches the phone accepted. Running the identical
/// expectations on both sides turns that divergence into a failing test here
/// rather than a disputed attendance record in production.
void main() {
  group('geodesy', () {
    test('measures zero between a point and itself', () {
      expect(haversineMeters(-6.2, 106.8, -6.2, 106.8), closeTo(0, 0.001));
    });

    test('measures ~111.19 km per degree of latitude at the equator', () {
      expect(
        haversineMeters(0, 0, 1, 0),
        closeTo(metersPerDegLat, 50),
      );
    });

    test('measures 111.195 km per degree at the equator, on either axis', () {
      // 2πR/360 with the IUGG mean radius. Longitude degrees shrink by
      // cos(latitude) away from the equator, so this is the shared maximum.
      expect(haversineMeters(0, 0, 1, 0), closeTo(metersPerDegLat, 1));
      expect(haversineMeters(0, 0, 0, 1), closeTo(metersPerDegLat, 1));
    });

    test('shrinks longitude degrees away from the equator', () {
      final atEquator = haversineMeters(0, 0, 0, 1);
      final at60 = haversineMeters(60, 0, 60, 1);
      // cos(60°) = 0.5.
      expect(at60, closeTo(atEquator * 0.5, 200));
    });

    test('matches a known Jakarta-to-Bandung great circle', () {
      // ~180 km by road; 116 km as the crow flies.
      expect(
        haversineMeters(-6.208763, 106.8456, -6.917465, 107.619122),
        closeTo(116000, 2000),
      );
    });

    test('is symmetric', () {
      final forward = haversineMeters(-6.208763, 106.8456, -7.872722, 111.462639);
      final backward = haversineMeters(-7.872722, 111.462639, -6.208763, 106.8456);
      expect(forward, closeTo(backward, 0.001));
    });

    test('rejects non-finite input rather than returning a plausible number', () {
      expect(haversineMeters(double.nan, 106.8, -6.2, 106.8).isNaN, isTrue);
      expect(haversineMeters(-6.2, double.infinity, -6.2, 106.8).isNaN, isTrue);
      expect(haversineMeters(-6.2, 106.8, null, 106.8).isNaN, isTrue);

      // A NaN distance must never compare as "inside", or the geofence stops
      // meaning anything.
      expect(isInsideRadius(double.nan, 106.8, -6.2, 106.8, 100), isFalse);
      expect(isInsideRadius(-6.2, 106.8, double.nan, 106.8, 100), isFalse);
      expect(isInsideRadius(-6.2, 106.8, -6.2, 106.8, double.nan), isFalse);
      expect(isInsideRadius(-6.2, 106.8, -6.2, 106.8, null), isFalse);
    });

    test('places a fix exactly on the radius boundary inside it', () {
      final distance = haversineMeters(-6.2, 106.8, -6.2, 106.8);
      expect(isInsideRadius(-6.2, 106.8, -6.2, 106.8, distance), isTrue);
    });

    test('excludes a fix just beyond the radius', () {
      const lng = 106.8 + 200 / 111320;
      expect(isInsideRadius(-6.2, lng, -6.2, 106.8, 100), isFalse);
    });

    test('validates coordinate ranges', () {
      expect(isValidCoordinate(-90, 180), isTrue, reason: 'extreme but legal');
      expect(isValidCoordinate(-90.1, 0), isFalse);
      expect(isValidCoordinate(0, 180.1), isFalse);
      expect(isValidCoordinate(double.nan, 0), isFalse);
      expect(isValidCoordinate(null, null), isFalse);
    });

    test('frames small radii closer than large ones', () {
      final tight = zoomForRadius(50);
      final loose = zoomForRadius(500);
      expect(tight, greaterThan(loose));
      expect(
        tight - loose,
        greaterThanOrEqualTo(2),
        reason: 'a factor of five is 2^2.3 levels, allowing for rounding',
      );
    });

    test('clamps the zoom to the map range', () {
      expect(zoomForRadius(2), 19, reason: 'tiny radius clamps at the maximum');
      expect(zoomForRadius(50000), 12, reason: 'huge radius clamps at the minimum');
      expect(zoomForRadius(0), 16, reason: 'falls back for a non-positive radius');
      expect(zoomForRadius(null), 16, reason: 'falls back for an absent radius');
      expect(zoomForRadius(double.nan), 16, reason: 'non-finite radius');
    });

    test('still shows the circle for the smallest allowed radius', () {
      // The dashboard allows 10 m, which asks for zoom 21 — past
      // OpenStreetMap's last tile level. Clamping to 19 leaves ~68 m of ground
      // across the picker, so the 20 m circle is visible with margin.
      expect(zoomForRadius(10, latitude: -7.87), 19);

      final metresAcrossAtMaxZoom =
          (metresPerPixelAtZoomZero * math.cos((-7.87 * math.pi) / 180)) /
              math.pow(2, 19) *
              384;
      expect(
        metresAcrossAtMaxZoom,
        greaterThan(2 * 10),
        reason: 'the picker must show more than 20 m across',
      );
    });

    test('frames a circle symmetrically across the equator', () {
      // cos(60°) = 0.5, so the same circle at 60°N must sit 1 level lower.
      final atEquator = zoomForRadius(100, latitude: 0);
      final at60 = zoomForRadius(100, latitude: 60);
      expect((at60 - atEquator).abs(), lessThanOrEqualTo(1));
    });

    test('converts metres to a latitude span', () {
      expect(metresToLatitudeDegrees(metersPerDegLat), closeTo(1, 1e-9));
      expect(haversineMeters(0, 0, 0, 0.001), closeTo(metersPerDegLat * 0.001, 5));
    });

    test('converts metres to a longitude span that shrinks with latitude', () {
      expect(metresToLongitudeDegrees(metersPerDegLat, 0), closeTo(1, 1e-9));
      // At 60°N a longitude degree is half as wide.
      expect(metresToLongitudeDegrees(metersPerDegLat, 60), closeTo(2, 1e-6));
    });

    test('formats coordinates and distances for display', () {
      expect(formatCoordinate(-6.2087634), '-6.208763');
      expect(formatCoordinate(double.nan), '—');
      expect(formatDistance(42.7), '43 m');
      expect(formatDistance(1450), '1.45 km');
      expect(formatDistance(double.nan), '—');
    });

    test('keeps the Earth radius consistent with the degree constant', () {
      // 2πR = 360 × (metres per degree). Pinning the two together means changing
      // one constant without the other fails here rather than quietly skewing
      // every distance in the app.
      const circumference = 2 * math.pi * earthRadiusMeters;
      expect(circumference, closeTo(360 * metersPerDegLat, 1));
    });

    test('recognises the null-island mock-location fingerprint', () {
      expect(isNullIsland(0, 0), isTrue);
      expect(isNullIsland(0.0, -0.0), isTrue);
      expect(isNullIsland(-6.2, 106.8), isFalse);
      // A real location near zero must not be mistaken for a mock.
      expect(isNullIsland(0.0000001, 0.0000001), isFalse);
      expect(isNullIsland(null, 0), isFalse);
    });

    test('builds a closed circle that reaches the radius in every direction', () {
      const centreLat = -6.208763;
      const centreLng = 106.8456;
      final vertices = circleVertices(
        centerLat: centreLat,
        centerLng: centreLng,
        radiusMeters: 150,
      );

      expect(vertices.length, 72);
      // Every vertex must sit on the circle, not inside a square that merely
      // contains it — an inscribed polygon is what makes the drawn geofence
      // match the distance the app actually measured.
      for (final vertex in vertices) {
        final distance = haversineMeters(centreLat, centreLng, vertex[0], vertex[1]);
        expect(distance, closeTo(150, 1.5), reason: 'vertex ${vertex[0]},${vertex[1]}');
      }
    });

    test('keeps a drawn circle valid at the poles', () {
      final vertices = circleVertices(
        centerLat: 89.9,
        centerLng: 179.9,
        radiusMeters: 2000,
      );
      for (final vertex in vertices) {
        expect(isValidCoordinate(vertex[0], vertex[1]), isTrue);
      }
    });
  });

  group('access control', () {
    test('gives an ADMIN every page regardless of the stored list', () {
      expect(resolveAccess(UserRole.admin, const []).length, 6);
    });

    test('gives an ADMIN full access even with a garbage stored list', () {
      expect(resolveAccess(UserRole.admin, 'nonsense').length, 6);
    });

    test('never delegates employees or settings', () {
      final granted = resolveAccess(UserRole.user, [
        'employees',
        'settings',
        'attendance',
        'profile',
      ]);
      // Editing either can grant or revoke access, so delegating them would
      // let a USER escalate. `firestore.rules` enforces the same restriction.
      expect(granted, isNot(contains(AccessPage.employees)));
      expect(granted, isNot(contains(AccessPage.settings)));
      expect(granted, contains(AccessPage.attendance));
      expect(granted, contains(AccessPage.profile));
    });

    test('drops unknown page names', () {
      final granted = resolveAccess(UserRole.user, ['attendance', 'root', '', 'admin']);
      expect(granted, [AccessPage.attendance]);
    });

    test('falls back to the USER defaults when nothing is stored', () {
      expect(resolveAccess(UserRole.user, null).length, 3);
    });

    test('treats a missing role as a USER, never as an ADMIN', () {
      expect(resolveAccess(null, ['employees']), isEmpty);
    });

    test('keeps the delegable list in step with the rules file', () {
      // firestore.rules declares the same four pages. If one side grows without
      // the other, the app would promise access the rules deny.
      expect(delegablePages.length, 4);
    });

    test('preserves canonical page order regardless of stored order', () {
      final granted = resolveAccess(UserRole.user, ['profile', 'attendance']);
      expect(
        granted.indexOf(AccessPage.attendance),
        lessThan(granted.indexOf(AccessPage.profile)),
      );
    });

    test('normalises to canonical order for a stored array', () {
      final pages = normalisePages(['profile', 'attendance'], const []);
      expect(pages, [AccessPage.attendance, AccessPage.profile]);
    });
  });

  group('day keys', () {
    test('formats a local day, never a UTC one', () {
      // 01:00 local on the 8th. `toIso8601String()` would report the 7th in WIB,
      // which is exactly the off-by-one that makes "today" queries match nothing.
      expect(toIsoDate(DateTime(2026, 10, 8, 1, 0, 0)), '2026-10-08');
    });

    test('emits today as a sortable local day', () {
      expect(todayIso(), matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    });

    test('keeps the local offset on a full timestamp', () {
      // `toIso8601String()` always emits `Z` and throws the offset away; this
      // must not.
      final stamp = toLocalIso(DateTime(2026, 10, 8, 14, 30, 0));
      expect(stamp, matches(RegExp(r'^\d{4}-\d{2}-\d{2}T14:30:00[+-]\d{2}:\d{2}$')));
    });

    test('parses a bare calendar day as local, not UTC', () {
      // 1st → 8th is seven days apart, so eight days once both endpoints count.
      expect(daysBetween('2026-10-01', '2026-10-08'), 8);
      expect(daysBetween('2026-10-01', '2026-10-01'), 1);
      expect(daysBetween('2026-10-08', '2026-10-01'), 0, reason: 'reversed range clamps to zero');
      expect(daysBetween('bukan tanggal', '2026-10-01'), 0);
    });

    test('crosses a month boundary when counting days', () {
      expect(daysBetween('2026-09-28', '2026-10-02'), 5);
      expect(daysBetween('2026-12-30', '2027-01-02'), 4);
    });

    test('displays a bare calendar day on the day it names', () {
      // Parsed as UTC this would render the 30th for anyone west of Greenwich.
      final rendered = formatDisplayDate('2026-10-01');
      expect(rendered, contains('1'));
      expect(rendered, isNot(contains('30')));
      expect(rendered, '1 Oktober 2026');
    });

    test('passes an unparseable date through untouched', () {
      expect(formatDisplayDate('bukan tanggal'), 'bukan tanggal');
    });

    test('rejects a rolled-forward impossible date', () {
      // `DateTime(2026, 2, 30)` silently becomes 2 March, which would file a
      // leave request on the wrong day.
      expect(parseDayKey('2026-02-30'), isNull);
      expect(parseDayKey('2026-13-01'), isNull);
      expect(parseDayKey('2026-10-08'), isNotNull);
    });

    test('takes two initials and skips empty name segments', () {
      expect(getInitials('Budi Santoso'), 'BS');
      expect(getInitials('Siti'), 'S');
      expect(getInitials('Budi  Santoso'), 'BS',
          reason: 'a double space is not an empty segment');
      expect(getInitials(''), '?');
    });

    test('adds days across a month boundary without rolling the day', () {
      expect(addDaysToIso('2026-01-31', 1), '2026-02-01');
      expect(addDaysToIso('2026-03-01', -1), '2026-02-28');
      expect(addDaysToIso('2024-03-01', -1), '2024-02-29', reason: 'leap year');
    });

    test('numbers weekdays the way shifts store them', () {
      // ISO: 1 = Monday … 7 = Sunday, which is also Dart's `weekday`.
      expect(isoWeekday(DateTime(2026, 10, 5)), 1, reason: 'Monday');
      expect(isoWeekday(DateTime(2026, 10, 11)), 7, reason: 'Sunday');
    });
  });
}