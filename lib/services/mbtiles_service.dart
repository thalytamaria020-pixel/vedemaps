// Mapas offline no formato MBTiles.
//
// Um arquivo .mbtiles é um banco SQLite com as "imagens" (tiles) do mapa,
// organizadas por nível de zoom, coluna e linha. Pode ser gerado:
//   - no QGIS (Processamento > Gerar tiles XYZ (MBTiles)), a partir de
//     imagens de satélite, mosaicos, cartas topográficas etc.;
//   - dentro do próprio app (tela Mapas offline > Baixar área).
//
// Aqui só são suportados MBTiles raster (PNG, JPG ou WEBP).

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class MbTilesInfo {
  const MbTilesInfo({
    required this.name,
    required this.minZoom,
    required this.maxZoom,
    required this.format,
    this.bounds,
  });

  final String name;
  final int minZoom;
  final int maxZoom;
  final String format;
  final LatLngBounds? bounds;
}

class MbTilesSource {
  MbTilesSource._(this.path, this.db, this.info)
      : tileProvider = MbTilesTileProvider(db, path);

  final String path;
  final Database db;
  final MbTilesInfo info;
  final MbTilesTileProvider tileProvider;

  static Future<MbTilesSource> open(String path) async {
    final db = await openDatabase(path, readOnly: true, singleInstance: false);
    final info = await readInfo(db, p.basenameWithoutExtension(path));
    return MbTilesSource._(path, db, info);
  }

  Future<void> close() => db.close();

  static Future<MbTilesInfo> readInfo(Database db, String fallbackName) async {
    final meta = <String, String>{};
    try {
      for (final r in await db.query('metadata')) {
        meta['${r['name']}'] = '${r['value']}';
      }
    } catch (_) {
      // arquivo sem tabela metadata: seguimos com os valores calculados
    }

    final metaMin = int.tryParse(meta['minzoom'] ?? '');
    final metaMax = int.tryParse(meta['maxzoom'] ?? '');
    int minZoom;
    int maxZoom;
    if (metaMin != null && metaMax != null) {
      minZoom = metaMin;
      maxZoom = metaMax;
    } else {
      final r = await db.rawQuery(
          'SELECT MIN(zoom_level) AS mn, MAX(zoom_level) AS mx FROM tiles');
      minZoom = metaMin ?? (r.first['mn'] as int?) ?? 0;
      maxZoom = metaMax ?? (r.first['mx'] as int?) ?? 18;
    }

    LatLngBounds? bounds;
    final b = meta['bounds']?.split(',').map((s) => double.tryParse(s.trim())).toList();
    if (b != null && b.length == 4 && !b.contains(null)) {
      bounds = LatLngBounds(LatLng(b[1]!, b[0]!), LatLng(b[3]!, b[2]!));
    }

    return MbTilesInfo(
      name: meta['name'] ?? fallbackName,
      minZoom: minZoom,
      maxZoom: maxZoom,
      format: meta['format'] ?? 'png',
      bounds: bounds,
    );
  }
}

/// Fornece ao flutter_map os tiles lidos do arquivo .mbtiles.
class MbTilesTileProvider extends TileProvider {
  MbTilesTileProvider(this.db, this.path);

  final Database db;
  final String path;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MbTilesImage(db, path, coordinates.z, coordinates.x, coordinates.y);
}

/// Imagem de um único tile. Tiles ausentes viram um pixel transparente,
/// assim o mapa de fundo (se houver) continua aparecendo por baixo.
@immutable
class MbTilesImage extends ImageProvider<MbTilesImage> {
  const MbTilesImage(this.db, this.path, this.z, this.x, this.y);

  final Database db;
  final String path;
  final int z, x, y;

  static final Uint8List _transparent = Uint8List.fromList(const [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x04, 0x00, 0x00, 0x00, 0xB5, 0x1C, 0x0C, 0x02, 0x00, 0x00, 0x00,
    0x0B, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x64, 0x60, 0x00, 0x00,
    0x00, 0x06, 0x00, 0x02, 0x30, 0x81, 0xD0, 0x2F, 0x00, 0x00, 0x00, 0x00,
    0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
  ]);

  @override
  Future<MbTilesImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<MbTilesImage>(this);

  @override
  ImageStreamCompleter loadImage(MbTilesImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1.0);

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    // O MBTiles usa o esquema TMS: a linha (y) é contada de baixo para cima.
    final tmsY = (1 << z) - 1 - y;
    Uint8List bytes = _transparent;
    try {
      final rows = await db.query(
        'tiles',
        columns: ['tile_data'],
        where: 'zoom_level = ? AND tile_column = ? AND tile_row = ?',
        whereArgs: [z, x, tmsY],
        limit: 1,
      );
      if (rows.isNotEmpty && rows.first['tile_data'] != null) {
        bytes = rows.first['tile_data'] as Uint8List;
      }
    } catch (_) {
      // banco fechado ou tile corrompido: mostra transparente
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      other is MbTilesImage &&
      other.path == path &&
      other.z == z &&
      other.x == x &&
      other.y == y;

  @override
  int get hashCode => Object.hash(path, z, x, y);
}
