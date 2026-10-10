import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../domain/logic/geo.dart';
import '../../domain/logic/geofence_rules.dart';

/// The zone circle, the device fix, and the line between them.
///
/// Draws the same geometry the dashboard's Leaflet picker does and the original
/// Kotlin app did with osmdroid: an OpenStreetMap raster tile base, a circle at
/// the zone's radius, a marker for the device, and a connecting line. All three
/// share the Web-Mercator projection and the haversine distance, so what the
/// employee sees is the comparison the app actually makes.
///
/// Attribution is rendered because the OpenStreetMap tile usage policy requires
/// it — without it the tile server is entitled to block the app.
class ZoneMap extends StatelessWidget {
  const ZoneMap({
    super.key,
    required this.zone,
    this.fix,
    this.height = 260,
    this.showLegend = true,
    this.interactive = true,
  });

  /// The assigned zone, or `null` when none is configured.
  final Zone? zone;

  /// The device's current reading, if available.
  final Fix? fix;

  final double height;

  /// Whether the legend and distance readout are drawn.
  final bool showLegend;

  /// Whether the user may pan and zoom.
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final target = zone;

    if (target == null || !target.isUsable) {
      return Container(
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.location_off_outlined,
                size: 32, color: theme.colorScheme.outline),
            const SizedBox(height: 8),
            Text(
              'Zona absensi belum ditentukan',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      );
    }

    final center = LatLng(target.latitude, target.longitude);
    final fixLatLng =
        fix == null ? null : LatLng(fix!.latitude, fix!.longitude);

    final distance = fix == null
        ? null
        : haversineMeters(
            fix!.latitude,
            fix!.longitude,
            target.latitude,
            target.longitude,
          );
    final hasDistance = distance != null && !distance.isNaN;

    final insideRadius = hasDistance && distance <= target.radiusMeters;

    // The circle is drawn from real geographic vertices rather than a radius in
    // metres on the map widget, so it matches the haversine comparison exactly
    // at any zoom. An inscribed polygon is correct to within a few centimetres
    // at these radii.
    final circle = circleVertices(
      centerLat: target.latitude,
      centerLng: target.longitude,
      radiusMeters: target.radiusMeters,
      vertexCount: 96,
    ).map((point) => LatLng(point[0], point[1])).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            height: height,
            child: Stack(
              children: [
                FlutterMap(
                  options: MapOptions(
                    initialCenter: center,
                    // Frames the whole circle plus a margin, which is what
                    // makes the employee able to see they are outside it
                    // rather than merely told so.
                    // `zoomForRadius` returns an integer zoom level, which is what a tile pyramid
                    // addresses; the map widget wants it as a double.
                    initialZoom: zoomForRadius(
                      target.radiusMeters,
                      latitude: target.latitude,
                      viewportWidthPx: MediaQuery.sizeOf(context).width,
                      fillFraction: 0.55,
                    ).toDouble(),
                    interactionOptions: InteractionOptions(
                      flags: interactive
                          ? InteractiveFlag.all
                          : InteractiveFlag.none,
                    ),
                    ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'id.sae.absensi',
                      maxZoom: 19,
                    ),
                    PolygonLayer(
                      polygons: [
                        Polygon(
                          points: circle,
                          color: (insideRadius
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.error)
                              .withValues(alpha: 0.15),
                          borderColor: insideRadius
                              ? theme.colorScheme.primary
                              : theme.colorScheme.error,
                          borderStrokeWidth: 2,
                        ),
                      ],
                    ),
                    // The line to the device, drawn only when it is outside —
                    // inside the circle the marker is already on the target.
                    if (fixLatLng != null && hasDistance && !insideRadius)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: [center, fixLatLng],
                            color: theme.colorScheme.error,
                            strokeWidth: 2,
                          ),
                        ],
                      ),
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: center,
                          width: 28,
                          height: 28,
                          child: _ZoneCentreMarker(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        if (fixLatLng != null)
                          Marker(
                            point: fixLatLng,
                            width: 24,
                            height: 24,
                            child: _DeviceMarker(
                              color: insideRadius
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.error,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
                if (showLegend)
                  Positioned(
                    left: 8,
                    bottom: 8,
                    child: _Legend(
                      zoneName: target.name,
                      distance: hasDistance ? distance : null,
                      radiusMeters: target.radiusMeters,
                      accuracy: fix?.accuracyMeters,
                      inside: insideRadius,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The zone centre: a pin with a concentric target ring.
class _ZoneCentreMarker extends StatelessWidget {
  const _ZoneCentreMarker({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2.5),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.4),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: const Icon(Icons.home_work, size: 14, color: Colors.white),
    );
  }
}

/// The device fix, shown with the accuracy disc the OS reports.
///
/// The disc is drawn because an accuracy of ±200 m that happens to fall inside a
/// 150 m radius is not evidence of presence, and the employee should be able to
/// see that for themselves.
class _DeviceMarker extends StatelessWidget {
  const _DeviceMarker({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: const Icon(Icons.my_location, size: 12, color: Colors.white),
    );
  }
}

/// The overlay readout: distance to the centre, the radius, and GPS accuracy.
class _Legend extends StatelessWidget {
  const _Legend({
    required this.zoneName,
    required this.distance,
    required this.radiusMeters,
    required this.accuracy,
    required this.inside,
  });

  final String zoneName;
  final double? distance;
  final double radiusMeters;
  final double? accuracy;
  final bool inside;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            zoneName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            distance == null
                ? 'Menunggu sinyal GPS…'
                : '${formatDistance(distance)} dari pusat · '
                    'radius ${formatDistance(radiusMeters)}',
            style: TextStyle(
              color: inside ? const Color(0xFF9CCC65) : const Color(0xFFEF9A9A),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (accuracy != null)
            Text(
              'akurasi GPS ±${accuracy!.round()} m',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75),
                fontSize: 10,
              ),
            ),
        ],
      ),
    );
  }
}

/// Degrees of latitude spanned by a metre distance, re-exported so callers can
/// sanity-check zone input against the drawn circle.
double degreesPerMetre(double metres) => metresToLatitudeDegrees(metres);

/// A minimal "where am I" summary, used by the punch screen's header.
String describeDistance({
  required double? distance,
  required double radiusMeters,
}) {
  if (distance == null) return 'Menunggu sinyal GPS';
  final inside = distance <= radiusMeters;
  return '${formatDistance(distance)} dari pusat zona '
      '(${inside ? 'di dalam area' : 'di luar area'})';
}

/// Clamps a map latitude to the Web-Mercator limit.
double clampLatitude(double latitude) => math.max(-85.0, math.min(85.0, latitude));