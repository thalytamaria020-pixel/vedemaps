// Leitura de arquivos KML (Google Earth). O KMZ é um ZIP com um KML dentro
// e é tratado no ImportService.

import 'package:latlong2/latlong.dart';
import 'package:xml/xml.dart';

import '../../models/vector_layer.dart';

class Kml {
  Kml._();

  /// Busca elementos pelo nome "local" (ignorando prefixos como "kml:").
  static Iterable<XmlElement> _find(XmlNode node, String name) =>
      node.descendants.whereType<XmlElement>().where((e) => e.name.local == name);

  static XmlElement? _child(XmlElement e, String name) {
    for (final c in e.childElements) {
      if (c.name.local == name) return c;
    }
    return null;
  }

  static List<LatLng> _coords(XmlElement? e) {
    if (e == null) return [];
    final coordsEl = e.name.local == 'coordinates' ? e : _find(e, 'coordinates').firstOrNull;
    if (coordsEl == null) return [];
    final out = <LatLng>[];
    for (final tuple in coordsEl.innerText.trim().split(RegExp(r'\s+'))) {
      final parts = tuple.split(',');
      if (parts.length < 2) continue;
      final lon = double.tryParse(parts[0]);
      final lat = double.tryParse(parts[1]);
      if (lat == null || lon == null) continue;
      if (lat < -90 || lat > 90 || lon < -180 || lon > 180) continue;
      out.add(LatLng(lat, lon));
    }
    return out;
  }

  static List<VectorFeature> parse(String text) {
    final doc = XmlDocument.parse(text);
    final out = <VectorFeature>[];

    for (final pm in _find(doc, 'Placemark')) {
      final props = <String, dynamic>{};
      final name = _child(pm, 'name')?.innerText.trim();
      if (name != null && name.isNotEmpty) props['name'] = name;
      final desc = _child(pm, 'description')?.innerText.trim();
      if (desc != null && desc.isNotEmpty) props['description'] = desc;
      // <ExtendedData><Data name="x"><value>..</value></Data>
      for (final d in _find(pm, 'Data')) {
        final key = d.getAttribute('name');
        final value = _child(d, 'value')?.innerText;
        if (key != null && value != null) props[key] = value;
      }
      // <SchemaData><SimpleData name="x">..</SimpleData>
      for (final d in _find(pm, 'SimpleData')) {
        final key = d.getAttribute('name');
        if (key != null) props[key] = d.innerText;
      }

      final points = _find(pm, 'Point').map(_coords).where((c) => c.isNotEmpty).map((c) => c.first).toList();
      final lines = _find(pm, 'LineString').map(_coords).where((c) => c.length >= 2).toList();
      final polygons = <PolygonRings>[];
      for (final pg in _find(pm, 'Polygon')) {
        final outer = _coords(_find(pg, 'outerBoundaryIs').firstOrNull);
        if (outer.length < 3) continue;
        final holes = _find(pg, 'innerBoundaryIs')
            .map(_coords)
            .where((c) => c.length >= 3)
            .toList();
        polygons.add(PolygonRings(outer, holes));
      }

      if (points.isNotEmpty) out.add(VectorFeature.fromPoints(points, Map.of(props)));
      if (lines.isNotEmpty) out.add(VectorFeature.fromLines(lines, Map.of(props)));
      if (polygons.isNotEmpty) out.add(VectorFeature.fromPolygons(polygons, Map.of(props)));
    }
    return out;
  }
}
