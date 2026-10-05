// Leitor de Shapefile (ESRI) escrito em Dart puro.
//
// Um "shapefile" é um conjunto de arquivos com o mesmo nome:
//   .shp  geometrias          .dbf  tabela de atributos
//   .prj  sistema de coordenadas (projeção)   .cpg  codificação do texto
//
// Suporta pontos, multipontos, linhas e polígonos (inclusive Z e M).
// Sistemas de coordenadas aceitos:
//   - geográficos (SIRGAS 2000 / WGS84; SAD69 é aceito com aviso)
//   - UTM (qualquer zona, N ou S), convertido para lat/long
// Outras projeções (ex.: Albers, Policônica) devem ser reprojetadas no QGIS.

import 'dart:convert';
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';

import '../../models/vector_layer.dart';
import '../../utils/geo_utils.dart';

class ShapefileException implements Exception {
  ShapefileException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ShapefileResult {
  ShapefileResult(this.features, this.warnings);
  final List<VectorFeature> features;
  final List<String> warnings;
}

typedef _Transform = LatLng? Function(double x, double y);

class Shapefile {
  Shapefile._();

  static ShapefileResult read({
    required Uint8List shp,
    Uint8List? dbf,
    String? prj,
    String? cpg,
  }) {
    final warnings = <String>[];
    final transform = _transformFor(prj, warnings);
    final records = dbf == null ? <Map<String, dynamic>>[] : _readDbf(dbf, cpg);
    if (dbf == null) warnings.add('Arquivo .dbf não encontrado: a camada ficará sem atributos.');

    final data = ByteData.sublistView(shp);
    if (shp.length < 100 || data.getInt32(0, Endian.big) != 9994) {
      throw ShapefileException('Arquivo .shp inválido ou corrompido.');
    }

    final features = <VectorFeature>[];
    var offset = 100;
    var index = 0;
    var skipped = 0;
    while (offset + 8 <= shp.length) {
      final contentLength = data.getInt32(offset + 4, Endian.big) * 2;
      final start = offset + 8;
      offset = start + contentLength;
      if (offset > shp.length || contentLength < 4) break;
      final props = index < records.length ? records[index] : <String, dynamic>{};
      index++;

      final type = data.getInt32(start, Endian.little);
      final f = _readShape(data, start, type, transform, props);
      if (f != null) {
        features.add(f);
      } else if (type != 0) {
        skipped++;
      }
    }
    if (skipped > 0) {
      warnings.add('$skipped feição(ões) ignorada(s) por coordenadas inválidas.');
    }
    return ShapefileResult(features, warnings);
  }

  // ------------------------------------------------------- Projeção (.prj)

  static _Transform _transformFor(String? prj, List<String> warnings) {
    LatLng? geographic(double x, double y) =>
        (y < -90 || y > 90 || x < -180 || x > 180) ? null : LatLng(y, x);

    if (prj == null || prj.trim().isEmpty) {
      warnings.add('Arquivo .prj ausente: assumindo coordenadas geográficas (SIRGAS 2000/WGS84).');
      return geographic;
    }
    final up = prj.toUpperCase();
    if (up.contains('SAD69') || up.contains('SAD_1969') || up.contains('CORREGO')) {
      warnings.add('Datum antigo (SAD69/Córrego Alegre) detectado: pode haver deslocamento de '
          'até ~70 m. Para precisão, reprojete para SIRGAS 2000 no QGIS.');
    }
    if (!up.contains('PROJCS')) return geographic;

    final m = RegExp(r'UTM[ _]ZONE[ _](\d{1,2})\s*([NS])').firstMatch(up);
    if (m != null) {
      final zone = int.parse(m.group(1)!);
      final south = m.group(2) == 'S';
      return (x, y) {
        if (x < 0 || x > 1000000 || y < 0 || y > 10000000) return null;
        return GeoUtils.fromUtm(zone, south, x, y);
      };
    }
    throw ShapefileException('Projeção não suportada. No QGIS, reprojete a camada para '
        'SIRGAS 2000 geográfico (EPSG:4674) ou UTM e importe novamente.');
  }

  // ------------------------------------------------------ Geometrias (.shp)

  static VectorFeature? _readShape(
    ByteData d,
    int start,
    int type,
    _Transform tf,
    Map<String, dynamic> props,
  ) {
    switch (type) {
      case 1: // Point
      case 11: // PointZ
      case 21: // PointM
        final p = tf(d.getFloat64(start + 4, Endian.little), d.getFloat64(start + 12, Endian.little));
        return p == null ? null : VectorFeature.fromPoints([p], props);

      case 8: // MultiPoint
      case 18:
      case 28:
        final n = d.getInt32(start + 36, Endian.little);
        final pts = <LatLng>[];
        for (var i = 0; i < n; i++) {
          final o = start + 40 + i * 16;
          final p = tf(d.getFloat64(o, Endian.little), d.getFloat64(o + 8, Endian.little));
          if (p == null) return null;
          pts.add(p);
        }
        return pts.isEmpty ? null : VectorFeature.fromPoints(pts, props);

      case 3: // PolyLine
      case 13:
      case 23:
      case 5: // Polygon
      case 15:
      case 25:
        final numParts = d.getInt32(start + 36, Endian.little);
        final numPoints = d.getInt32(start + 40, Endian.little);
        final partsStart = start + 44;
        final pointsStart = partsStart + numParts * 4;
        final parts = <List<LatLng>>[];
        final raw = <List<List<double>>>[]; // coordenadas originais (para orientação)
        for (var i = 0; i < numParts; i++) {
          final from = d.getInt32(partsStart + i * 4, Endian.little);
          final to = i + 1 < numParts ? d.getInt32(partsStart + (i + 1) * 4, Endian.little) : numPoints;
          final part = <LatLng>[];
          final rawPart = <List<double>>[];
          for (var k = from; k < to; k++) {
            final o = pointsStart + k * 16;
            final x = d.getFloat64(o, Endian.little);
            final y = d.getFloat64(o + 8, Endian.little);
            final p = tf(x, y);
            if (p == null) return null;
            part.add(p);
            rawPart.add([x, y]);
          }
          parts.add(part);
          raw.add(rawPart);
        }
        final isPolygon = type == 5 || type == 15 || type == 25;
        if (!isPolygon) {
          final lines = parts.where((l) => l.length >= 2).toList();
          return lines.isEmpty ? null : VectorFeature.fromLines(lines, props);
        }
        return _assemblePolygons(parts, raw, props);

      default:
        return null; // 0 = nulo; 31 = MultiPatch (não suportado)
    }
  }

  /// No shapefile, anéis externos são horários e furos são anti-horários.
  static bool isClockwise(List<List<double>> ring) {
    var sum = 0.0;
    for (var i = 0; i < ring.length - 1; i++) {
      sum += (ring[i + 1][0] - ring[i][0]) * (ring[i + 1][1] + ring[i][1]);
    }
    return sum > 0;
  }

  static VectorFeature? _assemblePolygons(
    List<List<LatLng>> parts,
    List<List<List<double>>> raw,
    Map<String, dynamic> props,
  ) {
    final polys = <PolygonRings>[];
    final holes = <List<LatLng>>[];
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].length < 3) continue;
      if (isClockwise(raw[i])) {
        polys.add(PolygonRings(parts[i]));
      } else {
        holes.add(parts[i]);
      }
    }
    if (polys.isEmpty) {
      // Arquivo com orientação invertida: trata todos os anéis como externos.
      polys.addAll(holes.map((h) => PolygonRings(h)));
      holes.clear();
    }
    for (final h in holes) {
      final owner = polys.firstWhere(
        (pg) => GeoUtils.pointInRing(h.first, pg.outer),
        orElse: () => polys.last,
      );
      owner.holes.add(h);
    }
    return polys.isEmpty ? null : VectorFeature.fromPolygons(polys, props);
  }

  // ------------------------------------------------------ Atributos (.dbf)

  static List<Map<String, dynamic>> _readDbf(Uint8List bytes, String? cpg) {
    if (bytes.length < 32) return [];
    final d = ByteData.sublistView(bytes);
    final numRecords = d.getUint32(4, Endian.little);
    final headerLength = d.getUint16(8, Endian.little);
    final recordLength = d.getUint16(10, Endian.little);
    final utf = cpg != null && cpg.toUpperCase().contains('UTF');

    String decode(List<int> b) {
      final s = utf ? utf8.decode(b, allowMalformed: true) : latin1.decode(b);
      return s.replaceAll('\u0000', '').trim();
    }

    // Descritores de campos: blocos de 32 bytes até o byte 0x0D.
    final fields = <({String name, String type, int length})>[];
    var pos = 32;
    while (pos + 32 <= headerLength && bytes[pos] != 0x0D) {
      final nameBytes = bytes.sublist(pos, pos + 11).takeWhile((b) => b != 0).toList();
      fields.add((
        name: latin1.decode(nameBytes).trim(),
        type: String.fromCharCode(bytes[pos + 11]),
        length: bytes[pos + 16],
      ));
      pos += 32;
    }

    final records = <Map<String, dynamic>>[];
    for (var r = 0; r < numRecords; r++) {
      var o = headerLength + r * recordLength;
      if (o + recordLength > bytes.length) break;
      o += 1; // byte de exclusão (' ' = ativo, '*' = excluído)
      final rec = <String, dynamic>{};
      for (final f in fields) {
        final text = decode(bytes.sublist(o, o + f.length));
        o += f.length;
        switch (f.type) {
          case 'N':
          case 'F':
            rec[f.name] = text.isEmpty ? null : num.tryParse(text) ?? text;
          case 'L':
            rec[f.name] = text.isEmpty ? null : 'YyTt'.contains(text);
          default:
            rec[f.name] = text;
        }
      }
      records.add(rec);
    }
    return records;
  }
}
