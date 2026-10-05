import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:verdemap/models/vector_layer.dart';
import 'package:verdemap/services/formats/geojson.dart';
import 'package:verdemap/services/formats/kml.dart';
import 'package:verdemap/services/formats/shapefile.dart';
import 'package:latlong2/latlong.dart';

/// Monta em memória um shapefile com 1 polígono (com furo) e seus atributos.
({Uint8List shp, Uint8List dbf}) _sampleShapefile() {
  final outer = [[-50.0, -10.0], [-50.0, -9.0], [-49.0, -9.0], [-49.0, -10.0], [-50.0, -10.0]];
  final hole = [[-49.6, -9.6], [-49.4, -9.6], [-49.4, -9.4], [-49.6, -9.4], [-49.6, -9.6]];
  final pts = [...outer, ...hole];

  const contentBytes = 4 + 32 + 4 + 4 + 2 * 4;
  final content = ByteData(contentBytes + pts.length * 16);
  content.setInt32(0, 5, Endian.little); // Polygon
  content.setFloat64(4, -50, Endian.little);
  content.setFloat64(12, -10, Endian.little);
  content.setFloat64(20, -49, Endian.little);
  content.setFloat64(28, -9, Endian.little);
  content.setInt32(36, 2, Endian.little); // partes
  content.setInt32(40, pts.length, Endian.little);
  content.setInt32(44, 0, Endian.little);
  content.setInt32(48, outer.length, Endian.little);
  for (var i = 0; i < pts.length; i++) {
    content.setFloat64(contentBytes + i * 16, pts[i][0], Endian.little);
    content.setFloat64(contentBytes + i * 16 + 8, pts[i][1], Endian.little);
  }

  final total = 100 + 8 + content.lengthInBytes;
  final shp = ByteData(total);
  shp.setInt32(0, 9994, Endian.big);
  shp.setInt32(24, total ~/ 2, Endian.big);
  shp.setInt32(28, 1000, Endian.little);
  shp.setInt32(32, 5, Endian.little);
  shp.setInt32(100, 1, Endian.big);
  shp.setInt32(104, content.lengthInBytes ~/ 2, Endian.big);
  final shpBytes = shp.buffer.asUint8List();
  shpBytes.setRange(108, total, content.buffer.asUint8List());

  // DBF com os campos NOME (texto, 20) e AREA_HA (número, 10)
  final dbf = BytesBuilder();
  final header = ByteData(32);
  header.setUint8(0, 0x03);
  header.setUint32(4, 1, Endian.little);
  header.setUint16(8, 32 + 32 * 2 + 1, Endian.little);
  header.setUint16(10, 1 + 20 + 10, Endian.little);
  dbf.add(header.buffer.asUint8List());
  Uint8List field(String name, String type, int len) {
    final f = Uint8List(32);
    f.setRange(0, name.length, latin1.encode(name));
    f[11] = type.codeUnitAt(0);
    f[16] = len;
    return f;
  }

  dbf
    ..add(field('NOME', 'C', 20))
    ..add(field('AREA_HA', 'N', 10))
    ..addByte(0x0D)
    ..add(latin1.encode(' ${'Área Embargada'.padRight(20)}${'12.50'.padLeft(10)}'))
    ..addByte(0x1A);

  return (shp: shpBytes, dbf: dbf.toBytes());
}

void main() {
  test('Shapefile: polígono com furo e atributos', () {
    final s = _sampleShapefile();
    final r = Shapefile.read(
      shp: s.shp,
      dbf: s.dbf,
      prj: 'GEOGCS["GCS_SIRGAS_2000",DATUM["D_SIRGAS_2000"]]',
    );
    expect(r.features, hasLength(1));
    final f = r.features.first;
    expect(f.kind, GeomKind.polygon);
    expect(f.polygons.single.holes, hasLength(1));
    expect(f.properties['NOME'], 'Área Embargada');
    expect(f.properties['AREA_HA'], 12.5);
    expect(f.containsPoint(const LatLng(-9.8, -49.8)), isTrue); // dentro
    expect(f.containsPoint(const LatLng(-9.5, -49.5)), isFalse); // no furo
    expect(f.containsPoint(const LatLng(-8.0, -49.5)), isFalse); // fora
  });

  test('Shapefile: projeção não suportada gera erro explicativo', () {
    final s = _sampleShapefile();
    expect(
      () => Shapefile.read(shp: s.shp, prj: 'PROJCS["Brazil_Polyconic"]'),
      throwsA(isA<ShapefileException>()),
    );
  });

  test('KML: ponto, linha e polígono com atributos', () {
    const kml = '''<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2"><Document>
  <Placemark><name>Ponto A</name><Point><coordinates>-60.1,-3.2,0</coordinates></Point></Placemark>
  <Placemark><name>Estrada</name><LineString><coordinates>-60,-3 -60.1,-3.1</coordinates></LineString></Placemark>
  <Placemark><name>UC</name>
    <ExtendedData><Data name="categoria"><value>Parque</value></Data></ExtendedData>
    <Polygon><outerBoundaryIs><LinearRing><coordinates>
      -61,-4 -60,-4 -60,-3 -61,-3 -61,-4
    </coordinates></LinearRing></outerBoundaryIs></Polygon>
  </Placemark>
</Document></kml>''';
    final fs = Kml.parse(kml);
    expect(fs.map((f) => f.kind).toList(), [GeomKind.point, GeomKind.line, GeomKind.polygon]);
    expect(fs.first.points.single, const LatLng(-3.2, -60.1));
    expect(fs.last.properties['categoria'], 'Parque');
    expect(fs.last.containsPoint(const LatLng(-3.5, -60.5)), isTrue);
  });

  test('GeoJSON: ida e volta mantém geometrias e atributos', () {
    final original = [
      VectorFeature.fromPolygons([
        PolygonRings(const [LatLng(0, 0), LatLng(0, 1), LatLng(1, 1), LatLng(1, 0)]),
      ], {'nome': 'Área 1'}),
      VectorFeature.fromPoints(const [LatLng(-3, -60)], {'nome': 'P1'}),
    ];
    final back = GeoJson.parse(GeoJson.encode(original));
    expect(back, hasLength(2));
    expect(back.first.kind, GeomKind.polygon);
    expect(back.first.properties['nome'], 'Área 1');
    expect(back.last.points.single, const LatLng(-3, -60));
  });
}
