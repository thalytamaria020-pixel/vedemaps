// Leitura e escrita de GeoJSON (RFC 7946). As coordenadas do GeoJSON vêm
// na ordem [longitude, latitude].

import 'dart:convert';

import 'package:latlong2/latlong.dart';

import '../../models/vector_layer.dart';

class GeoJson {
  GeoJson._();

  static List<VectorFeature> parse(String text) {
    final root = jsonDecode(text);
    final out = <VectorFeature>[];
    _parseObject(root, out, {});
    return out;
  }

  static void _parseObject(dynamic obj, List<VectorFeature> out, Map<String, dynamic> props) {
    if (obj is! Map) return;
    switch (obj['type']) {
      case 'FeatureCollection':
        for (final f in (obj['features'] as List? ?? const [])) {
          _parseObject(f, out, {});
        }
      case 'Feature':
        final p = (obj['properties'] as Map?)?.cast<String, dynamic>() ?? {};
        _parseGeometry(obj['geometry'], out, Map<String, dynamic>.from(p));
      default:
        _parseGeometry(obj, out, props);
    }
  }

  static LatLng? _pt(dynamic c) {
    if (c is! List || c.length < 2) return null;
    final lon = (c[0] as num).toDouble();
    final lat = (c[1] as num).toDouble();
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
    return LatLng(lat, lon);
  }

  static List<LatLng> _line(dynamic c) =>
      (c as List).map(_pt).whereType<LatLng>().toList();

  static PolygonRings? _poly(dynamic c) {
    final rings = (c as List).map(_line).where((r) => r.length >= 3).toList();
    if (rings.isEmpty) return null;
    return PolygonRings(rings.first, rings.skip(1).toList());
  }

  static void _parseGeometry(dynamic g, List<VectorFeature> out, Map<String, dynamic> props) {
    if (g is! Map) return;
    final c = g['coordinates'];
    switch (g['type']) {
      case 'Point':
        final p = _pt(c);
        if (p != null) out.add(VectorFeature.fromPoints([p], props));
      case 'MultiPoint':
        final pts = _line(c);
        if (pts.isNotEmpty) out.add(VectorFeature.fromPoints(pts, props));
      case 'LineString':
        final l = _line(c);
        if (l.length >= 2) out.add(VectorFeature.fromLines([l], props));
      case 'MultiLineString':
        final ls = (c as List).map(_line).where((l) => l.length >= 2).toList();
        if (ls.isNotEmpty) out.add(VectorFeature.fromLines(ls, props));
      case 'Polygon':
        final pg = _poly(c);
        if (pg != null) out.add(VectorFeature.fromPolygons([pg], props));
      case 'MultiPolygon':
        final pgs = (c as List).map(_poly).whereType<PolygonRings>().toList();
        if (pgs.isNotEmpty) out.add(VectorFeature.fromPolygons(pgs, props));
      case 'GeometryCollection':
        for (final sub in (g['geometries'] as List? ?? const [])) {
          _parseGeometry(sub, out, props);
        }
    }
  }

  // ------------------------------------------------------------ Escrita

  static List<double> _c(LatLng p) => [
        double.parse(p.longitude.toStringAsFixed(7)),
        double.parse(p.latitude.toStringAsFixed(7)),
      ];

  static Map<String, dynamic> _closed(List<LatLng> ring) {
    final pts = ring.map(_c).toList();
    if (pts.isNotEmpty &&
        (pts.first[0] != pts.last[0] || pts.first[1] != pts.last[1])) {
      pts.add(pts.first);
    }
    return {'r': pts};
  }

  static Map<String, dynamic> geometryOf(VectorFeature f) {
    switch (f.kind) {
      case GeomKind.point:
        return f.points.length == 1
            ? {'type': 'Point', 'coordinates': _c(f.points.first)}
            : {'type': 'MultiPoint', 'coordinates': f.points.map(_c).toList()};
      case GeomKind.line:
        return {
          'type': 'MultiLineString',
          'coordinates': f.lines.map((l) => l.map(_c).toList()).toList(),
        };
      case GeomKind.polygon:
        return {
          'type': 'MultiPolygon',
          'coordinates': f.polygons
              .map((pg) => [
                    _closed(pg.outer)['r'],
                    for (final h in pg.holes) _closed(h)['r'],
                  ])
              .toList(),
        };
    }
  }

  static String encode(List<VectorFeature> features) => jsonEncode({
        'type': 'FeatureCollection',
        'features': [
          for (final f in features)
            {
              'type': 'Feature',
              'properties': f.properties,
              'geometry': geometryOf(f),
            },
        ],
      });
}
