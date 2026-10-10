/// Geospatial helpers, mirroring `SAE-Dashboard/src/lib/geo.ts`.
///
/// The dashboard performs the identical haversine calculation, so a distance
/// shown there matches the number this app decided on. If the two drift, the
/// dashboard will reject a punch the phone accepted — which is the fastest way
/// to lose trust in the attendance record. The test suite asserts the same
/// reference distances as the dashboard's own tests so a divergence fails here
/// first.
library;

import 'dart:math' as math;

/// IUGG mean Earth radius, in metres.
///
/// Shared so the derived constants below are computed from the radius rather
/// than copied from a table that could drift independently.
const double earthRadiusMeters = 6371008.8;

/// Metres in one degree of latitude, derived as `2πR / 360`.
///
/// The commonly quoted 111 320 m is the value for the *equatorial* radius; the
/// mean radius gives ~111 195 m, which is what the haversine below actually
/// produces. Keeping both derived means they cannot disagree.
const double metersPerDegLat = (2 * math.pi * earthRadiusMeters) / 360;

/// Ground resolution in metres per pixel at zoom 0, on the equator.
///
/// `2πR / 256` for the standard 256 px Web-Mercator tile. Leaflet, flutter_map
/// and osmdroid share this projection, so all three scale it by
/// `cos(latitude) / 2^zoom`.
const double metresPerPixelAtZoomZero = (2 * math.pi * earthRadiusMeters) / 256;

/// Largest accepted GPS accuracy, in metres.
///
/// Anything coarser than this is treated as unusable for a geofence decision:
/// a fix that could be a kilometre away cannot honestly certify a 50 m zone.
const double maxAcceptableAccuracyMeters = 100.0;

/// True only for a finite real number.
///
/// Mirrors the dashboard's `isNumber`: rejects `null`, `NaN` and infinities so
/// the arithmetic below never propagates a nonsense distance.
bool isFiniteNumber(num? value) {
  if (value == null) return false;
  if (value is double) return value.isFinite;
  // Integers are finite by construction; a very large int is still finite, and
  // `int` cannot represent NaN or infinity in Dart.
  return true;
}

/// Great-circle distance between two WGS84 points, in metres.
///
/// Returns [double.nan] when any input is missing or non-finite, so a caller
/// that forgets to check surfaces an "unknown distance" rather than a
/// confidently wrong `0`.
double haversineMeters(
  num? lat1,
  num? lng1,
  num? lat2,
  num? lng2,
) {
  if (!isFiniteNumber(lat1) ||
      !isFiniteNumber(lng1) ||
      !isFiniteNumber(lat2) ||
      !isFiniteNumber(lng2)) {
    return double.nan;
  }

  double toRad(double degrees) => degrees * math.pi / 180.0;

  final dLat = toRad(lat2!.toDouble() - lat1!.toDouble());
  final dLng = toRad(lng2!.toDouble() - lng1!.toDouble());

  final a =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(toRad(lat1.toDouble())) *
          math.cos(toRad(lat2.toDouble())) *
          math.pow(math.sin(dLng / 2), 2);

  // `min(1, …)` guards asin against a value fractionally above 1 from floating
  // point error, which would otherwise return NaN for two identical points.
  return 2 * earthRadiusMeters * math.asin(math.min(1.0, math.sqrt(a)));
}

/// True when the fix falls inside the zone.
///
/// An unmeasurable distance is *outside*: a punch that cannot be located is
/// never allowed to pass a geofence.
bool isInsideRadius(
  num? fixLat,
  num? fixLng,
  num? zoneLat,
  num? zoneLng,
  num? radiusMeters,
) {
  final distance = haversineMeters(fixLat, fixLng, zoneLat, zoneLng);
  if (distance.isNaN || !isFiniteNumber(radiusMeters)) return false;
  return distance <= radiusMeters!;
}

/// Latitude/longitude valid for Firestore and the geofence comparison.
bool isValidCoordinate(num? latitude, num? longitude) {
  return isFiniteNumber(latitude) &&
      isFiniteNumber(longitude) &&
      latitude!.abs() <= 90 &&
      longitude!.abs() <= 180;
}

/// Map zoom level that frames a circle of [radiusMeters].
///
/// At zoom `z` the ground resolution is `m/px = 156543.034 × cos(lat) / 2^z`, so
/// the zoom at which a circle of radius `r` fills [fillFraction] of a
/// [viewportWidthPx] container is
/// `z = log2(156543.034 × cos(lat) × fillFraction × viewport / (2r))`.
///
/// Two details are load-bearing: the `cos(latitude)` factor keeps the circle
/// round on screen, and the **diameter** (2r) is what must fit, not the radius.
int zoomForRadius(
  num? radiusMeters, {
  num latitude = 0,
  double viewportWidthPx = 384,
  double fillFraction = 0.6,
  int min = 12,
  int max = 19,
}) {
  if (!isFiniteNumber(radiusMeters) || radiusMeters! <= 0) return 16;

  // `|| 1` guards the degenerate case where cos() is 0 or rounds to 0, which
  // would otherwise make the zoom negative infinity.
  final latitudeScale = math.cos(latitude * math.pi / 180.0).abs();
  final scale = latitudeScale == 0 ? 1.0 : latitudeScale;

  final zoom = (math.log(
            metresPerPixelAtZoomZero * scale * fillFraction * viewportWidthPx /
                (2 * radiusMeters),
          ) /
          math.ln2);

  if (zoom.isNaN) return 16;
  return zoom.round().clamp(min, max);
}

/// Six decimals is ~11 cm, which is well below GPS noise but above rounding
/// error.
String formatCoordinate(num? value) {
  if (!isFiniteNumber(value)) return '—';
  return value!.toDouble().toStringAsFixed(6);
}

/// Compact distance for tables: metres below 1 km, kilometres above.
String formatDistance(num? meters) {
  if (!isFiniteNumber(meters)) return '—';
  final value = meters!.toDouble();
  if (value < 1000) return '${value.round()} m';
  return '${(value / 1000).toStringAsFixed(2)} km';
}

/// Degrees spanned by [metres] of latitude; handy for sanity-checking input.
double metresToLatitudeDegrees(num metres) => metres / metersPerDegLat;

/// Longitude degrees spanned by [metres] at [latitude].
///
/// Longitude degrees shrink towards the poles, so this is what keeps a drawn
/// circle circular instead of an ellipse.
double metresToLongitudeDegrees(num metres, num latitude) {
  final cos = math.cos(latitude * math.pi / 180.0);
  if (cos.abs() < 1e-12) return 0;
  return metres / (metersPerDegLat * cos);
}

/// Builds a circle of [vertexCount] points around a centre.
///
/// The dashboard draws the same shape as a Leaflet `L.circle` and the old
/// Android app as an osmdroid `Polygon`. All three approximate a circle in
/// geographic coordinates, so at a 2000 m radius the vertices must be dense
/// enough that the polygon does not visibly cut the corner at high zoom.
List<List<double>> circleVertices({
  required double centerLat,
  required double centerLng,
  required double radiusMeters,
  int vertexCount = 72,
}) {
  final points = <List<double>>[];
  final latDelta = metresToLatitudeDegrees(radiusMeters);
  final lngDelta = metresToLongitudeDegrees(radiusMeters, centerLat);

  for (var i = 0; i < vertexCount; i++) {
    final angle = (2 * math.pi * i) / vertexCount;
    points.add([
      (centerLat + latDelta * math.sin(angle)).clamp(-90.0, 90.0),
      (centerLng + lngDelta * math.cos(angle)).clamp(-180.0, 180.0),
    ]);
  }
  return points;
}

/// True when a fix is the classic `0,0` mock-location fingerprint.
///
/// An emulator or a rooting tool reports exactly this. It is *outside* every
/// real zone by a huge margin, so the geofence already rejects it — checking it
/// explicitly lets the UI say why instead of showing an unexplained
/// "di luar area".
bool isNullIsland(num? latitude, num? longitude) {
  if (!isFiniteNumber(latitude) || !isFiniteNumber(longitude)) return false;
  return latitude!.toDouble() == 0 && longitude!.toDouble() == 0;
}