// Mapas em PDF georreferenciado (como no Avenza Maps).
//
// Na importação, a página do PDF é desenhada uma única vez em blocos de
// imagem (1024 × 1024 px), em dois níveis:
//   - visão geral: a página inteira com 2048 px no lado maior;
//   - detalhe: a página com 8192 px no lado maior (usado ao aproximar).
// Cada bloco recebe as coordenadas exatas dos seus cantos, calculadas a
// partir do georreferenciamento do PDF. Assim o mapa fica alinhado ao GPS
// mesmo quando está em UTM, e não é preciso abrir o PDF de novo em campo.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import '../utils/geo_utils.dart';
import 'formats/geopdf.dart';

/// Um bloco de imagem e a posição dos seus cantos no terreno.
class GeoPdfCell {
  GeoPdfCell(this.file, this.topLeft, this.bottomLeft, this.bottomRight);

  final String file;
  final LatLng topLeft;
  final LatLng bottomLeft;
  final LatLng bottomRight;

  LatLng get topRight => LatLng(
        topLeft.latitude + bottomRight.latitude - bottomLeft.latitude,
        topLeft.longitude + bottomRight.longitude - bottomLeft.longitude,
      );

  late final LatLngBounds bounds =
      LatLngBounds.fromPoints([topLeft, bottomLeft, bottomRight, topRight]);

  static List<double> _ll(LatLng p) => [p.latitude, p.longitude];
  static LatLng _pt(dynamic v) =>
      LatLng(((v as List)[0] as num).toDouble(), (v[1] as num).toDouble());

  Map<String, dynamic> toJson() => {
        'file': file,
        'tl': _ll(topLeft),
        'bl': _ll(bottomLeft),
        'br': _ll(bottomRight),
      };

  factory GeoPdfCell.fromJson(Map<String, dynamic> j) =>
      GeoPdfCell(j['file'] as String, _pt(j['tl']), _pt(j['bl']), _pt(j['br']));
}

/// Mapa PDF já preparado, guardado em uma pasta com as imagens e um info.json.
class GeoPdfMap {
  GeoPdfMap({
    required this.dir,
    required this.name,
    required this.visible,
    required this.opacity,
    required this.switchZoom,
    required this.overview,
    required this.detail,
    required this.warnings,
  });

  final String dir;
  String name;
  bool visible;
  double opacity;

  /// Acima deste zoom, usa os blocos de detalhe.
  final double switchZoom;
  final List<GeoPdfCell> overview;
  final List<GeoPdfCell> detail;
  final List<String> warnings;

  late final LatLngBounds bounds =
      LatLngBounds.fromPoints([for (final c in overview) ...[c.topLeft, c.bottomLeft, c.bottomRight, c.topRight]]);

  String path(GeoPdfCell c) => p.join(dir, c.file);

  Map<String, dynamic> toJson() => {
        'name': name,
        'visible': visible,
        'opacity': opacity,
        'switchZoom': switchZoom,
        'overview': overview.map((c) => c.toJson()).toList(),
        'detail': detail.map((c) => c.toJson()).toList(),
        'warnings': warnings,
      };

  static GeoPdfMap fromJson(String dir, Map<String, dynamic> j) => GeoPdfMap(
        dir: dir,
        name: j['name'] as String,
        visible: j['visible'] as bool? ?? true,
        opacity: (j['opacity'] as num?)?.toDouble() ?? 1.0,
        switchZoom: (j['switchZoom'] as num).toDouble(),
        overview: (j['overview'] as List)
            .map((e) => GeoPdfCell.fromJson(e as Map<String, dynamic>))
            .toList(),
        detail: (j['detail'] as List)
            .map((e) => GeoPdfCell.fromJson(e as Map<String, dynamic>))
            .toList(),
        warnings: (j['warnings'] as List? ?? const []).cast<String>(),
      );

  Future<void> save() async {
    await File(p.join(dir, 'info.json')).writeAsString(jsonEncode(toJson()));
  }

  /// Carrega todos os mapas PDF da pasta [root].
  static Future<List<GeoPdfMap>> loadAll(String root) async {
    final out = <GeoPdfMap>[];
    final d = Directory(root);
    if (!await d.exists()) return out;
    await for (final e in d.list()) {
      if (e is! Directory) continue;
      final f = File(p.join(e.path, 'info.json'));
      if (!await f.exists()) continue;
      try {
        out.add(GeoPdfMap.fromJson(
            e.path, jsonDecode(await f.readAsString()) as Map<String, dynamic>));
      } catch (err) {
        debugPrint('Mapa PDF ignorado (${e.path}): $err');
      }
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }
}

class GeoPdfService {
  GeoPdfService._();

  static const int cellSize = 1024;
  static const int overviewSize = 2048;
  static const int detailSize = 8192;

  static (int, int) _dims(double aspect, int longSide) => aspect >= 1
      ? (longSide, (longSide / aspect).round())
      : ((longSide * aspect).round(), longSide);

  static int _cellCount(double aspect, int longSide) {
    final (w, h) = _dims(aspect, longSide);
    return (w / cellSize).ceil() * (h / cellSize).ceil();
  }

  /// Lê o georreferenciamento, desenha os blocos e grava tudo em uma pasta
  /// nova dentro de [root]. [onProgress] recebe valores de 0 a 1.
  static Future<GeoPdfMap> importPdf(
    String pdfPath,
    String root, {
    required String name,
    void Function(double progress)? onProgress,
  }) async {
    // 1. Georreferenciamento (em outra isolate, para não travar a tela)
    final info = await compute(GeoPdf.parseFile, pdfPath);

    final dir = Directory(p.join(root, 'pdf_${DateTime.now().millisecondsSinceEpoch}'));
    await dir.create(recursive: true);

    try {
      // 2. Desenho da página em blocos
      await pdfrxFlutterInitialize(); // prepara a biblioteca PDFium
      final doc = await PdfDocument.openFile(pdfPath);
      try {
        if (info.pageIndex >= doc.pages.length) {
          throw GeoPdfException('Página georreferenciada não encontrada no PDF.');
        }
        final page = doc.pages[info.pageIndex];
        final aspect = info.aspect;
        final total = _cellCount(aspect, overviewSize) + _cellCount(aspect, detailSize);
        var done = 0;

        Future<List<GeoPdfCell>> level(String prefix, int longSide) async {
          final (w, h) = _dims(aspect, longSide);
          final nx = (w / cellSize).ceil();
          final ny = (h / cellSize).ceil();
          final cells = <GeoPdfCell>[];
          for (var j = 0; j < ny; j++) {
            for (var i = 0; i < nx; i++) {
              final x0 = i * cellSize;
              final y0 = j * cellSize;
              final cw = math.min(cellSize, w - x0);
              final ch = math.min(cellSize, h - y0);
              final img = await page.render(
                x: x0,
                y: y0,
                width: cw,
                height: ch,
                fullWidth: w.toDouble(),
                fullHeight: h.toDouble(),
                backgroundColor: 0xFFFFFFFF, // fundo branco
              );
              if (img == null) throw GeoPdfException('Não foi possível desenhar o PDF.');
              final uiImage = await img.createImage();
              img.dispose();
              final png = await uiImage.toByteData(format: ui.ImageByteFormat.png);
              uiImage.dispose();
              if (png == null) throw GeoPdfException('Falha ao gerar a imagem do mapa.');

              final file = '${prefix}_${i}_$j.png';
              await File(p.join(dir.path, file)).writeAsBytes(png.buffer.asUint8List());
              final s0 = x0 / w, s1 = (x0 + cw) / w;
              final t0 = y0 / h, t1 = (y0 + ch) / h;
              cells.add(GeoPdfCell(
                file,
                info.normToLatLng(s0, t0),
                info.normToLatLng(s0, t1),
                info.normToLatLng(s1, t1),
              ));
              done++;
              onProgress?.call(done / total);
            }
          }
          return cells;
        }

        final overview = await level('g', overviewSize);
        final detail = await level('d', detailSize);

        // 3. Zoom em que a visão geral começa a ficar "pixelada"
        final left = info.normToLatLng(0, 0.5);
        final right = info.normToLatLng(1, 0.5);
        final (ow, _) = _dims(aspect, overviewSize);
        final metersPerPixel = GeoUtils.distance(left, right) / ow;
        final cosLat = math.cos(left.latitude * math.pi / 180).abs();
        final switchZoom = metersPerPixel > 0
            ? math.log(156543.03392 * cosLat / metersPerPixel) / math.ln2
            : 14.0;

        final map = GeoPdfMap(
          dir: dir.path,
          name: name,
          visible: true,
          opacity: 1.0,
          switchZoom: switchZoom,
          overview: overview,
          detail: detail,
          warnings: info.warnings,
        );
        await map.save();
        return map;
      } finally {
        await doc.dispose();
      }
    } catch (_) {
      // Falhou no meio: não deixa pasta pela metade ocupando espaço.
      if (await dir.exists()) await dir.delete(recursive: true);
      rethrow;
    }
  }
}
