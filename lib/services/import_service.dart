// Importação de camadas vetoriais: KML, KMZ, GeoJSON e Shapefile (.zip).

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/vector_layer.dart';
import 'formats/geojson.dart';
import 'formats/kml.dart';
import 'formats/shapefile.dart';

class ImportException implements Exception {
  ImportException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ImportResult {
  ImportResult(this.name, this.features, this.warnings);
  final String name;
  final List<VectorFeature> features;
  final List<String> warnings;
}

class ImportService {
  ImportService._();

  static const supportedExtensions = ['.kml', '.kmz', '.geojson', '.json', '.zip', '.shp'];

  /// Lê o arquivo em uma "isolate" (thread separada) para não travar a tela
  /// com arquivos grandes, como camadas do CAR ou de embargos.
  static Future<ImportResult> importFile(String path) {
    return compute(_importSync, path);
  }

  static ImportResult _importSync(String path) {
    final ext = p.extension(path).toLowerCase();
    final name = p.basenameWithoutExtension(path);
    final bytes = File(path).readAsBytesSync();

    switch (ext) {
      case '.kml':
        return ImportResult(name, Kml.parse(_text(bytes)), []);
      case '.geojson':
      case '.json':
        return ImportResult(name, GeoJson.parse(_text(bytes)), []);
      case '.kmz':
        return ImportResult(name, _fromKmz(bytes), []);
      case '.zip':
        return _fromZip(name, bytes);
      case '.shp':
        final r = Shapefile.read(shp: bytes);
        return ImportResult(name, r.features, [
          ...r.warnings,
          'Dica: compacte .shp, .dbf, .prj e .cpg juntos em um .zip para importar os atributos.',
        ]);
      default:
        throw ImportException(
            'Formato não suportado ($ext). Use KML, KMZ, GeoJSON ou Shapefile compactado (.zip).');
    }
  }

  static String _text(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);

  static List<VectorFeature> _fromKmz(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final f in archive.files) {
      if (f.isFile && f.name.toLowerCase().endsWith('.kml')) {
        return Kml.parse(_text(f.content));
      }
    }
    throw ImportException('O KMZ não contém nenhum arquivo .kml.');
  }

  static ImportResult _fromZip(String name, Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    // Agrupa os arquivos do zip pelo nome base (ex.: "embargos.shp", "embargos.dbf").
    final byBase = <String, Map<String, Uint8List>>{};
    for (final f in archive.files) {
      if (!f.isFile) continue;
      final fileName = p.basename(f.name);
      if (fileName.startsWith('._')) continue; // lixo gerado pelo macOS
      final ext = p.extension(fileName).toLowerCase();
      final base = p.basenameWithoutExtension(fileName).toLowerCase();
      byBase.putIfAbsent(base, () => {})[ext] =
          Uint8List.fromList(f.content);
    }

    final features = <VectorFeature>[];
    final warnings = <String>[];
    for (final entry in byBase.entries) {
      final files = entry.value;
      final shp = files['.shp'];
      if (shp == null) continue;
      final r = Shapefile.read(
        shp: shp,
        dbf: files['.dbf'],
        prj: files['.prj'] == null ? null : latin1.decode(files['.prj']!),
        cpg: files['.cpg'] == null ? null : latin1.decode(files['.cpg']!),
      );
      features.addAll(r.features);
      warnings.addAll(r.warnings.map((w) => byBase.length > 1 ? '${entry.key}: $w' : w));
    }
    if (features.isNotEmpty) return ImportResult(name, features, warnings);

    // Sem shapefile? Tenta KML ou GeoJSON dentro do zip.
    for (final files in byBase.values) {
      if (files['.kml'] != null) return ImportResult(name, Kml.parse(_text(files['.kml']!)), []);
      final gj = files['.geojson'] ?? files['.json'];
      if (gj != null) return ImportResult(name, GeoJson.parse(_text(gj)), []);
    }
    throw ImportException('Nenhum shapefile, KML ou GeoJSON válido encontrado no .zip.');
  }
}
