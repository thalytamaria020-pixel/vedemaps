// Download de uma área do mapa para um arquivo .mbtiles (uso offline).

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

class DownloadProgress {
  const DownloadProgress({
    required this.done,
    required this.total,
    required this.failed,
    required this.bytes,
    this.finished = false,
    this.cancelled = false,
  });

  final int done;
  final int total;
  final int failed;
  final int bytes;
  final bool finished;
  final bool cancelled;

  double get fraction => total == 0 ? 0 : done / total;
}

class CancelToken {
  bool cancelled = false;
  void cancel() => cancelled = true;
}

typedef TileId = ({int z, int x, int y});

class TileDownloader {
  TileDownloader._();

  /// Limite de segurança para não lotar o armazenamento do aparelho.
  static const int maxTiles = 60000;

  /// Tamanho médio estimado de um tile (para exibir uma previsão).
  static const int avgTileBytes = 25 * 1024;

  static int _tileX(double lon, int z) {
    final n = 1 << z;
    return ((lon + 180) / 360 * n).floor().clamp(0, n - 1);
  }

  static int _tileY(double lat, int z) {
    final n = 1 << z;
    final latRad = lat.clamp(-85.0511, 85.0511) * math.pi / 180;
    final y = (1 - math.log(math.tan(latRad) + 1 / math.cos(latRad)) / math.pi) / 2 * n;
    return y.floor().clamp(0, n - 1);
  }

  static Iterable<TileId> tilesIn(LatLngBounds b, int minZoom, int maxZoom) sync* {
    for (var z = minZoom; z <= maxZoom; z++) {
      final x0 = _tileX(b.west, z), x1 = _tileX(b.east, z);
      final y0 = _tileY(b.north, z), y1 = _tileY(b.south, z);
      for (var x = x0; x <= x1; x++) {
        for (var y = y0; y <= y1; y++) {
          yield (z: z, x: x, y: y);
        }
      }
    }
  }

  static int countTiles(LatLngBounds b, int minZoom, int maxZoom) {
    var total = 0;
    for (var z = minZoom; z <= maxZoom; z++) {
      final dx = _tileX(b.east, z) - _tileX(b.west, z) + 1;
      final dy = _tileY(b.south, z) - _tileY(b.north, z) + 1;
      total += dx * dy;
    }
    return total;
  }

  static String buildUrl(String template, int z, int x, int y) => template
      .replaceAll('{z}', '$z')
      .replaceAll('{x}', '$x')
      .replaceAll('{y}', '$y')
      .replaceAll('{s}', 'abc'[(x + y) % 3]);

  static String _detectFormat(Uint8List b) {
    if (b.length > 3 && b[0] == 0xFF && b[1] == 0xD8) return 'jpg';
    if (b.length > 12 && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
      return 'webp';
    }
    return 'png';
  }

  /// Baixa os tiles e grava no arquivo [outputPath]. Se o arquivo já existir,
  /// os novos tiles são acrescentados (útil para complementar uma área).
  static Stream<DownloadProgress> download({
    required String urlTemplate,
    required LatLngBounds bounds,
    required int minZoom,
    required int maxZoom,
    required String outputPath,
    required String name,
    required CancelToken cancel,
    int concurrency = 4,
  }) {
    final controller = StreamController<DownloadProgress>();

    Future<void> run() async {
      final db = await openDatabase(outputPath, version: 1, onCreate: (db, v) async {
        await db.execute('CREATE TABLE IF NOT EXISTS metadata (name TEXT, value TEXT)');
        await db.execute('CREATE UNIQUE INDEX IF NOT EXISTS metadata_name ON metadata(name)');
        await db.execute('CREATE TABLE IF NOT EXISTS tiles (zoom_level INTEGER, '
            'tile_column INTEGER, tile_row INTEGER, tile_data BLOB)');
        await db.execute('CREATE UNIQUE INDEX IF NOT EXISTS tile_index ON tiles '
            '(zoom_level, tile_column, tile_row)');
      });

      final tiles = tilesIn(bounds, minZoom, maxZoom).toList();
      final client = http.Client();
      var next = 0, done = 0, failed = 0, bytes = 0;
      String? format;

      void emit() => controller.add(DownloadProgress(
          done: done, total: tiles.length, failed: failed, bytes: bytes));

      Future<void> worker() async {
        while (!cancel.cancelled && next < tiles.length) {
          final t = tiles[next++];
          try {
            final resp = await client
                .get(Uri.parse(buildUrl(urlTemplate, t.z, t.x, t.y)),
                    headers: {'User-Agent': 'VerdeMap/1.0 (uso institucional)'})
                .timeout(const Duration(seconds: 30));
            final ct = resp.headers['content-type'] ?? 'image';
            if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty && ct.startsWith('image')) {
              await db.insert(
                'tiles',
                {
                  'zoom_level': t.z,
                  'tile_column': t.x,
                  'tile_row': (1 << t.z) - 1 - t.y,
                  'tile_data': resp.bodyBytes,
                },
                conflictAlgorithm: ConflictAlgorithm.replace,
              );
              bytes += resp.bodyBytes.length;
              format ??= _detectFormat(resp.bodyBytes);
            } else {
              failed++;
            }
          } catch (_) {
            failed++;
          }
          done++;
          if (done % 5 == 0 || done == tiles.length) emit();
        }
      }

      await Future.wait(List.generate(concurrency, (_) => worker()));
      client.close();

      // Metadados: o zoom e os limites passam a cobrir tudo que existe no arquivo.
      final agg = await db.rawQuery(
          'SELECT MIN(zoom_level) AS mn, MAX(zoom_level) AS mx FROM tiles');
      final meta = {
        'name': name,
        'format': format ?? 'png',
        'type': 'baselayer',
        'version': '1.0',
        'minzoom': '${agg.first['mn'] ?? minZoom}',
        'maxzoom': '${agg.first['mx'] ?? maxZoom}',
        'bounds': '${bounds.west},${bounds.south},${bounds.east},${bounds.north}',
      };
      final old = await db.query('metadata', where: 'name = ?', whereArgs: ['bounds']);
      if (old.isNotEmpty) {
        final ob = '${old.first['value']}'.split(',').map(double.tryParse).toList();
        if (ob.length == 4 && !ob.contains(null)) {
          meta['bounds'] = '${math.min(ob[0]!, bounds.west)},${math.min(ob[1]!, bounds.south)},'
              '${math.max(ob[2]!, bounds.east)},${math.max(ob[3]!, bounds.north)}';
        }
      }
      for (final e in meta.entries) {
        await db.insert('metadata', {'name': e.key, 'value': e.value},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await db.close();

      controller.add(DownloadProgress(
        done: done,
        total: tiles.length,
        failed: failed,
        bytes: bytes,
        finished: true,
        cancelled: cancel.cancelled,
      ));
      await controller.close();
    }

    run().catchError((Object e) {
      controller.addError(e);
      controller.close();
    });
    return controller.stream;
  }
}
