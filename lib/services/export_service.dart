// Exportação de dados de campo: KML (Google Earth), GeoJSON (QGIS),
// GPX (trilhas), CSV (planilhas) e um pacote .zip completo com fotos.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/field_point.dart';
import '../models/track.dart';
import '../utils/geo_utils.dart';

class ExportService {
  ExportService._();

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  static String stamp([DateTime? d]) {
    final t = d ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}';
  }

  static String formatDateTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.day)}/${two(t.month)}/${t.year} ${two(t.hour)}:${two(t.minute)}';
  }

  // ------------------------------------------------------------- Pontos

  static String pointsToKml(List<FieldPoint> pts) {
    final b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<kml xmlns="http://www.opengis.net/kml/2.2"><Document>')
      ..writeln('<name>Pontos de campo - ${stamp()}</name>');
    for (final pt in pts) {
      final utm = GeoUtils.toUtm(pt.latitude, pt.longitude);
      b
        ..writeln('<Placemark>')
        ..writeln('<name>${_esc(pt.title)}</name>')
        ..writeln('<description>${_esc(pt.notes)}</description>')
        ..writeln('<ExtendedData>');
      final data = {
        'categoria': pt.category,
        'data_hora': formatDateTime(pt.createdAt),
        'utm': utm.toString(),
        'precisao_m': pt.accuracy?.toStringAsFixed(1) ?? '',
        'altitude_m': pt.altitude?.toStringAsFixed(1) ?? '',
        'fotos': pt.photos.join('; '),
      };
      data.forEach((k, v) => b.writeln('<Data name="$k"><value>${_esc(v)}</value></Data>'));
      b
        ..writeln('</ExtendedData>')
        ..writeln('<Point><coordinates>${pt.longitude},${pt.latitude}</coordinates></Point>')
        ..writeln('</Placemark>');
    }
    b.writeln('</Document></kml>');
    return b.toString();
  }

  static String pointsToGeoJson(List<FieldPoint> pts) => const JsonEncoder.withIndent(' ').convert({
        'type': 'FeatureCollection',
        'features': [
          for (final pt in pts)
            {
              'type': 'Feature',
              'geometry': {
                'type': 'Point',
                'coordinates': [pt.longitude, pt.latitude],
              },
              'properties': {
                'id': pt.id,
                'titulo': pt.title,
                'categoria': pt.category,
                'observacoes': pt.notes,
                'data_hora': pt.createdAt.toIso8601String(),
                'precisao_m': pt.accuracy,
                'altitude_m': pt.altitude,
                'utm': GeoUtils.toUtm(pt.latitude, pt.longitude).toString(),
                'fotos': pt.photos.map((f) => 'fotos/$f').toList(),
              },
            },
        ],
      });

  /// CSV com separador ";" (abre direto no Excel/LibreOffice em português).
  static String pointsToCsv(List<FieldPoint> pts) {
    String q(String s) => '"${s.replaceAll('"', '""')}"';
    final b = StringBuffer('﻿') // BOM: acentos corretos no Excel
      ..writeln('id;data_hora;categoria;titulo;latitude;longitude;zona_utm;utm_e;utm_n;'
          'precisao_m;altitude_m;observacoes;fotos');
    for (final pt in pts) {
      final u = GeoUtils.toUtm(pt.latitude, pt.longitude);
      b.writeln([
        pt.id ?? '',
        formatDateTime(pt.createdAt),
        q(pt.category),
        q(pt.title),
        pt.latitude.toStringAsFixed(7),
        pt.longitude.toStringAsFixed(7),
        '${u.zone}${u.band}',
        u.easting.toStringAsFixed(1),
        u.northing.toStringAsFixed(1),
        pt.accuracy?.toStringAsFixed(1) ?? '',
        pt.altitude?.toStringAsFixed(1) ?? '',
        q(pt.notes),
        q(pt.photos.join(', ')),
      ].join(';'));
    }
    return b.toString();
  }

  // ------------------------------------------------------------ Trilhas

  static String trackToGpx(Track t, List<TrackPoint> pts) {
    final b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<gpx version="1.1" creator="VerdeMap" '
          'xmlns="http://www.topografix.com/GPX/1/1">')
      ..writeln('<trk><name>${_esc(t.name)}</name><trkseg>');
    for (final tp in pts) {
      b.write('<trkpt lat="${tp.latitude}" lon="${tp.longitude}">');
      if (tp.altitude != null) b.write('<ele>${tp.altitude!.toStringAsFixed(1)}</ele>');
      b.writeln('<time>${tp.time.toUtc().toIso8601String()}</time></trkpt>');
    }
    b.writeln('</trkseg></trk></gpx>');
    return b.toString();
  }

  static String trackToKml(Track t, List<TrackPoint> pts) {
    final coords = pts.map((tp) => '${tp.longitude},${tp.latitude}').join(' ');
    return '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<kml xmlns="http://www.opengis.net/kml/2.2"><Document>'
        '<Style id="trilha"><LineStyle><color>ff0000ff</color><width>3</width></LineStyle></Style>'
        '<Placemark><name>${_esc(t.name)}</name>'
        '<description>Distância: ${GeoUtils.formatDistance(t.distanceMeters)} - '
        'Início: ${formatDateTime(t.startedAt)}</description>'
        '<styleUrl>#trilha</styleUrl>'
        '<LineString><tessellate>1</tessellate><coordinates>$coords</coordinates></LineString>'
        '</Placemark></Document></kml>';
  }

  // ------------------------------------------------------------ Arquivos

  static Future<Directory> _exportDir() async {
    final dir = Directory(p.join((await getTemporaryDirectory()).path, 'exportacao'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<File> writeText(String fileName, String content) async {
    final f = File(p.join((await _exportDir()).path, fileName));
    return f.writeAsString(content, flush: true);
  }

  /// Pacote completo: pontos (GeoJSON, KML, CSV), trilhas (GPX) e fotos.
  static Future<File> buildPackage({
    required List<FieldPoint> points,
    required Map<Track, List<TrackPoint>> tracks,
    required String photosDir,
  }) async {
    final archive = Archive();
    void addText(String name, String text) {
      final bytes = utf8.encode(text);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    addText('pontos.geojson', pointsToGeoJson(points));
    addText('pontos.kml', pointsToKml(points));
    addText('pontos.csv', pointsToCsv(points));
    var i = 1;
    for (final e in tracks.entries) {
      final safe = e.key.name.replaceAll(RegExp(r'[^\w\-]+'), '_');
      addText('trilhas/${i++}_$safe.gpx', trackToGpx(e.key, e.value));
    }
    for (final pt in points) {
      for (final photo in pt.photos) {
        final f = File(p.join(photosDir, photo));
        if (await f.exists()) {
          final bytes = await f.readAsBytes();
          archive.addFile(ArchiveFile('fotos/$photo', bytes.length, bytes));
        }
      }
    }
    final data = ZipEncoder().encode(archive);
    final out = File(p.join((await _exportDir()).path, 'verdemap_${stamp()}.zip'));
    return out.writeAsBytes(data, flush: true);
  }

  /// Abre o menu de compartilhamento do sistema (WhatsApp, e-mail, Drive...).
  static Future<void> share(List<File> files, {String? text}) async {
    await Share.shareXFiles(files.map((f) => XFile(f.path)).toList(), text: text);
  }
}
