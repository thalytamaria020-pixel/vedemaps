import 'package:latlong2/latlong.dart';

import '../utils/geo_utils.dart';

/// Tipo de geometria de uma feição importada.
enum GeomKind { point, line, polygon }

/// Retângulo envolvente (usado para acelerar buscas espaciais).
class BBox {
  BBox(this.minLat, this.minLon, this.maxLat, this.maxLon);

  factory BBox.of(Iterable<LatLng> pts) {
    var minLat = 90.0, minLon = 180.0, maxLat = -90.0, maxLon = -180.0;
    for (final p in pts) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }
    return BBox(minLat, minLon, maxLat, maxLon);
  }

  final double minLat, minLon, maxLat, maxLon;

  bool contains(LatLng p) =>
      p.latitude >= minLat &&
      p.latitude <= maxLat &&
      p.longitude >= minLon &&
      p.longitude <= maxLon;

  BBox union(BBox o) => BBox(
        minLat < o.minLat ? minLat : o.minLat,
        minLon < o.minLon ? minLon : o.minLon,
        maxLat > o.maxLat ? maxLat : o.maxLat,
        maxLon > o.maxLon ? maxLon : o.maxLon,
      );
}

/// Polígono com um anel externo e zero ou mais furos.
class PolygonRings {
  PolygonRings(this.outer, [List<List<LatLng>>? holes]) : holes = holes ?? [];

  final List<LatLng> outer;
  final List<List<LatLng>> holes;

  BBox? _bbox;
  BBox get bbox => _bbox ??= BBox.of(outer);

  bool contains(LatLng p) {
    if (!bbox.contains(p)) return false;
    if (!GeoUtils.pointInRing(p, outer)) return false;
    for (final h in holes) {
      if (GeoUtils.pointInRing(p, h)) return false;
    }
    return true;
  }
}

/// Uma feição (registro) de uma camada importada: geometria + atributos.
class VectorFeature {
  VectorFeature.fromPoints(this.points, [Map<String, dynamic>? props])
      : kind = GeomKind.point,
        lines = const [],
        polygons = const [],
        properties = props ?? {};

  VectorFeature.fromLines(this.lines, [Map<String, dynamic>? props])
      : kind = GeomKind.line,
        points = const [],
        polygons = const [],
        properties = props ?? {};

  VectorFeature.fromPolygons(this.polygons, [Map<String, dynamic>? props])
      : kind = GeomKind.polygon,
        points = const [],
        lines = const [],
        properties = props ?? {};

  final GeomKind kind;
  final List<LatLng> points;
  final List<List<LatLng>> lines;
  final List<PolygonRings> polygons;
  final Map<String, dynamic> properties;

  Iterable<LatLng> get allCoords sync* {
    yield* points;
    for (final l in lines) {
      yield* l;
    }
    for (final pg in polygons) {
      yield* pg.outer;
    }
  }

  bool containsPoint(LatLng p) => polygons.any((pg) => pg.contains(p));

  /// Nome amigável da feição (procura atributos comuns).
  String get label {
    for (final k in const ['name', 'nome', 'NOME', 'Name', 'NAME', 'nm', 'cod_imovel', 'COD_IMOVEL']) {
      final v = properties[k];
      if (v != null && v.toString().trim().isNotEmpty) return v.toString();
    }
    return 'Feição sem nome';
  }
}

/// Camada vetorial importada (KML, KMZ, GeoJSON ou Shapefile).
class VectorLayer {
  VectorLayer({
    this.id,
    required this.name,
    required this.colorValue,
    this.visible = true,
    required this.fileName,
    required this.featureCount,
    required this.createdAt,
    List<VectorFeature>? features,
  }) : features = features ?? [];

  final int? id;
  final String name;
  final int colorValue; // cor ARGB
  final bool visible;
  final String fileName; // arquivo GeoJSON na pasta "camadas"
  final int featureCount;
  final DateTime createdAt;
  List<VectorFeature> features; // carregado do arquivo em tempo de execução

  BBox? get bbox {
    BBox? box;
    for (final f in features) {
      final coords = f.allCoords.toList();
      if (coords.isEmpty) continue;
      final b = BBox.of(coords);
      box = box == null ? b : box.union(b);
    }
    return box;
  }

  VectorLayer copyWith({int? id, String? name, int? colorValue, bool? visible}) =>
      VectorLayer(
        id: id ?? this.id,
        name: name ?? this.name,
        colorValue: colorValue ?? this.colorValue,
        visible: visible ?? this.visible,
        fileName: fileName,
        featureCount: featureCount,
        createdAt: createdAt,
        features: features,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'color': colorValue,
        'visible': visible ? 1 : 0,
        'file_name': fileName,
        'feature_count': featureCount,
        'created_at': createdAt.toIso8601String(),
      };

  factory VectorLayer.fromMap(Map<String, Object?> m) => VectorLayer(
        id: m['id'] as int?,
        name: m['name'] as String,
        colorValue: m['color'] as int,
        visible: (m['visible'] as int) == 1,
        fileName: m['file_name'] as String,
        featureCount: (m['feature_count'] as int?) ?? 0,
        createdAt: DateTime.parse(m['created_at'] as String),
      );
}
