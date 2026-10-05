// Leitura do georreferenciamento de PDFs (o mesmo tipo de mapa que o
// Avenza Maps abre).
//
// Padrão suportado: "Geospatial PDF" da norma ISO 32000 (Adobe), usado por
// QGIS, ArcGIS, GDAL, IBGE e pela maioria dos mapas exportados hoje. Nele,
// a página tem uma "janela" (viewport, /VP) com um dicionário /Measure que
// liga pontos da página (/LPTS) a coordenadas geográficas (/GPTS) e informa
// o sistema de coordenadas (/GCS).
//
// O padrão antigo da TerraGo/OGC (/LGIDict) é detectado e recusado com uma
// orientação para converter no QGIS.
//
// Este arquivo só lê a "matemática" do mapa (Dart puro, testável). O desenho
// do PDF em imagens fica em geopdf_service.dart.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:latlong2/latlong.dart';

import '../../utils/geo_utils.dart';

class GeoPdfException implements Exception {
  GeoPdfException(this.message);
  final String message;
  @override
  String toString() => message;
}

// ===================================================================
// Mini-leitor de PDF (só o necessário para achar o georreferenciamento)
// ===================================================================

class PdfRef {
  const PdfRef(this.number);
  final int number;
}

class PdfName {
  const PdfName(this.value);
  final String value;
  @override
  bool operator ==(Object other) => other is PdfName && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => '/$value';
}

class PdfKeyword {
  const PdfKeyword(this.value);
  final String value;
}

/// Analisador de valores PDF: números, nomes, textos, listas, dicionários
/// e referências ("12 0 R").
class PdfParser {
  PdfParser(this.s, [this.pos = 0]);

  final String s;
  int pos;

  static const _delims = '()<>[]{}/%';

  static bool _isWs(int c) =>
      c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0x00;

  static bool _isDelim(int c) => _delims.codeUnits.contains(c);

  void skipWs() {
    while (pos < s.length) {
      final c = s.codeUnitAt(pos);
      if (_isWs(c)) {
        pos++;
      } else if (c == 0x25) {
        // comentário: vai até o fim da linha
        while (pos < s.length && s.codeUnitAt(pos) != 0x0A && s.codeUnitAt(pos) != 0x0D) {
          pos++;
        }
      } else {
        break;
      }
    }
  }

  String _regular() {
    final start = pos;
    while (pos < s.length) {
      final c = s.codeUnitAt(pos);
      if (_isWs(c) || _isDelim(c)) break;
      pos++;
    }
    return s.substring(start, pos);
  }

  dynamic parse() {
    skipWs();
    if (pos >= s.length) throw const FormatException('Fim inesperado do PDF');
    final c = s.codeUnitAt(pos);
    if (c == 0x3C) {
      // '<<' dicionário ou '<' texto hexadecimal
      if (pos + 1 < s.length && s.codeUnitAt(pos + 1) == 0x3C) {
        pos += 2;
        return _dict();
      }
      pos++;
      return _hex();
    }
    if (c == 0x5B) {
      pos++;
      return _array();
    }
    if (c == 0x28) {
      pos++;
      return _literal();
    }
    if (c == 0x2F) {
      pos++;
      return PdfName(_regular());
    }
    final word = _regular();
    if (word.isEmpty) {
      pos++; // delimitador solto (ex.: ')' ou '>'): ignora
      return null;
    }
    if (word == 'true') return true;
    if (word == 'false') return false;
    if (word == 'null') return null;
    final n = num.tryParse(word.endsWith('.') ? '${word}0' : word);
    if (n == null) return PdfKeyword(word);
    if (n is int) {
      // Pode ser uma referência: "<número> <geração> R"
      final save = pos;
      skipWs();
      final gen = int.tryParse(_regular());
      if (gen != null) {
        skipWs();
        if (pos < s.length &&
            s.codeUnitAt(pos) == 0x52 &&
            (pos + 1 >= s.length ||
                _isWs(s.codeUnitAt(pos + 1)) ||
                _isDelim(s.codeUnitAt(pos + 1)))) {
          pos++;
          return PdfRef(n);
        }
      }
      pos = save;
    }
    return n;
  }

  Map<String, dynamic> _dict() {
    final map = <String, dynamic>{};
    while (true) {
      skipWs();
      if (pos >= s.length) break;
      if (s.startsWith('>>', pos)) {
        pos += 2;
        break;
      }
      final key = parse();
      if (key is! PdfName) continue;
      map[key.value] = parse();
    }
    return map;
  }

  List<dynamic> _array() {
    final list = <dynamic>[];
    while (true) {
      skipWs();
      if (pos >= s.length) break;
      if (s.codeUnitAt(pos) == 0x5D) {
        pos++;
        break;
      }
      list.add(parse());
    }
    return list;
  }

  String _hex() {
    final end = s.indexOf('>', pos);
    if (end < 0) throw const FormatException('Texto hexadecimal sem fim');
    var hex = s.substring(pos, end).replaceAll(RegExp(r'\s'), '');
    pos = end + 1;
    if (hex.length.isOdd) hex += '0';
    final out = StringBuffer();
    for (var i = 0; i + 1 < hex.length; i += 2) {
      final v = int.tryParse(hex.substring(i, i + 2), radix: 16);
      if (v != null) out.writeCharCode(v);
    }
    return out.toString();
  }

  String _literal() {
    final out = StringBuffer();
    var depth = 1;
    while (pos < s.length) {
      final c = s.codeUnitAt(pos++);
      if (c == 0x5C && pos < s.length) {
        // barra invertida: sequência de escape
        final e = s.codeUnitAt(pos++);
        switch (e) {
          case 0x6E:
            out.write('\n');
          case 0x72:
            out.write('\r');
          case 0x74:
            out.write('\t');
          case 0x62:
            out.write('\b');
          case 0x66:
            out.write('\f');
          case 0x0D:
            if (pos < s.length && s.codeUnitAt(pos) == 0x0A) pos++;
          case 0x0A:
            break;
          default:
            if (e >= 0x30 && e <= 0x37) {
              var oct = e - 0x30;
              for (var k = 0; k < 2 && pos < s.length; k++) {
                final d = s.codeUnitAt(pos);
                if (d < 0x30 || d > 0x37) break;
                oct = oct * 8 + (d - 0x30);
                pos++;
              }
              out.writeCharCode(oct & 0xFF);
            } else {
              out.writeCharCode(e);
            }
        }
        continue;
      }
      if (c == 0x28) depth++;
      if (c == 0x29) {
        depth--;
        if (depth == 0) break;
      }
      out.writeCharCode(c);
    }
    return out.toString();
  }
}

/// Todos os objetos de um arquivo PDF, inclusive os guardados dentro de
/// "object streams" compactados (PDF 1.5 ou mais novo).
class PdfFile {
  PdfFile(this.s) {
    _scan();
    _expandObjectStreams();
  }

  final String s; // conteúdo do arquivo decodificado como Latin-1 (1 char = 1 byte)
  final Map<int, dynamic> objects = {};
  final Map<int, (int, int)> _streams = {};

  static final _objRe = RegExp(r'(\d+)\s+(\d+)\s+obj\b');

  void _scan() {
    var from = 0;
    while (true) {
      final it = _objRe.allMatches(s, from).iterator;
      if (!it.moveNext()) break;
      final m = it.current;
      final number = int.parse(m.group(1)!);
      final parser = PdfParser(s, m.end);
      dynamic value;
      try {
        value = parser.parse();
      } catch (_) {
        from = m.end;
        continue;
      }
      objects[number] = value;
      from = parser.pos;

      parser.skipWs();
      if (s.startsWith('stream', parser.pos)) {
        var start = parser.pos + 6;
        if (s.startsWith('\r\n', start)) {
          start += 2;
        } else if (start < s.length &&
            (s.codeUnitAt(start) == 0x0A || s.codeUnitAt(start) == 0x0D)) {
          start += 1;
        }
        final len = value is Map ? value['Length'] : null;
        int end;
        if (len is int && start + len <= s.length) {
          end = start + len;
        } else {
          final e = s.indexOf('endstream', start);
          if (e < 0) break;
          end = e;
          if (end > start && s.codeUnitAt(end - 1) == 0x0A) end--;
          if (end > start && s.codeUnitAt(end - 1) == 0x0D) end--;
        }
        _streams[number] = (start, end);
        from = end; // pula os dados binários do stream
      }
    }
  }

  List<int>? streamBytes(int number) {
    final st = _streams[number];
    final dict = objects[number];
    if (st == null || dict is! Map) return null;
    var data = s.substring(st.$1, st.$2).codeUnits;
    final f = resolve(dict['Filter']);
    final filters = f == null ? const [] : (f is List ? f : [f]);
    for (final filter in filters) {
      if (resolve(filter) == const PdfName('FlateDecode')) {
        try {
          data = ZLibDecoder().decodeBytes(data);
        } catch (_) {
          return null;
        }
      } else {
        return null; // outros filtros não são usados em object streams
      }
    }
    return data;
  }

  void _expandObjectStreams() {
    for (final entry in objects.entries.toList()) {
      final d = entry.value;
      if (d is! Map || d['Type'] != const PdfName('ObjStm')) continue;
      final bytes = streamBytes(entry.key);
      if (bytes == null) continue;
      final text = latin1.decode(bytes);
      final n = resolve(d['N']);
      final first = resolve(d['First']);
      if (n is! int || first is! int) continue;
      final header = PdfParser(text);
      final pairs = <(int, int)>[];
      try {
        for (var i = 0; i < n; i++) {
          final number = header.parse();
          final offset = header.parse();
          if (number is int && offset is int) pairs.add((number, offset));
        }
      } catch (_) {
        continue;
      }
      for (final (number, offset) in pairs) {
        if (objects.containsKey(number)) continue;
        try {
          objects[number] = PdfParser(text, first + offset).parse();
        } catch (_) {
          // objeto ilegível: ignorado
        }
      }
    }
  }

  dynamic resolve(dynamic v) {
    var cur = v;
    for (var i = 0; i < 32 && cur is PdfRef; i++) {
      cur = objects[cur.number];
    }
    return cur is PdfRef ? null : cur;
  }

  Map? dict(dynamic v) {
    final r = resolve(v);
    return r is Map ? r : null;
  }

  /// Páginas na ordem do documento.
  List<Map> pages() {
    Map? root;
    for (final o in objects.values) {
      if (o is Map && o['Type'] == const PdfName('Pages') && o['Parent'] == null) {
        root = o;
        break;
      }
    }
    final out = <Map>[];
    void walk(Map node, int depth) {
      if (depth > 64) return;
      final kids = resolve(node['Kids']);
      if (kids is! List) return;
      for (final k in kids) {
        final d = dict(k);
        if (d == null) continue;
        if (d['Type'] == const PdfName('Pages')) {
          walk(d, depth + 1);
        } else {
          out.add(d);
        }
      }
    }

    if (root != null) walk(root, 0);
    if (out.isEmpty) {
      out.addAll(objects.values.whereType<Map>().where((o) => o['Type'] == const PdfName('Page')));
    }
    return out;
  }

  /// Atributo de página que pode ser herdado do nó pai (MediaBox, Rotate...).
  dynamic inherited(Map page, String key) {
    Map? node = page;
    for (var i = 0; node != null && i < 64; i++) {
      if (node.containsKey(key)) return resolve(node[key]);
      node = dict(node['Parent']);
    }
    return null;
  }

  List<double>? numbers(dynamic v) {
    final r = resolve(v);
    if (r is! List) return null;
    final out = <double>[];
    for (final x in r) {
      final n = resolve(x);
      if (n is! num) return null;
      out.add(n.toDouble());
    }
    return out;
  }
}

// ===================================================================
// Georreferenciamento
// ===================================================================

/// Resultado da leitura: como converter um ponto da imagem da página em
/// latitude/longitude.
class GeoPdfInfo {
  GeoPdfInfo({
    required this.pageIndex,
    required this.pageBox,
    required this.rotate,
    required this.projection,
    required this.utmZone,
    required this.utmSouth,
    required this.affine,
    required this.warnings,
  });

  final int pageIndex;

  /// Caixa visível da página (CropBox ou MediaBox): x0, y0, x1, y1 em pontos.
  final List<double> pageBox;

  /// Rotação da página em graus (0, 90, 180, 270).
  final int rotate;

  /// 'geo' (lat/long), 'utm' ou 'aprox' (projeção não reconhecida).
  final String projection;
  final int utmZone;
  final bool utmSouth;

  /// Transformação afim: página = A · projetado + t
  /// px = a·X + b·Y + c ;  py = d·X + e·Y + f
  final List<double> affine;
  final List<String> warnings;

  /// Proporção largura/altura da página como ela aparece na tela.
  double get aspect {
    final w = pageBox[2] - pageBox[0];
    final h = pageBox[3] - pageBox[1];
    return (rotate == 90 || rotate == 270) ? h / w : w / h;
  }

  /// Converte um ponto da imagem desenhada (s, t de 0 a 1, a partir do
  /// canto superior esquerdo) em latitude/longitude.
  LatLng normToLatLng(double s, double t) {
    // Desfaz a rotação da página
    double a, b; // posição na página sem rotação (a: da esquerda, b: do topo)
    switch (rotate) {
      case 90:
        a = t;
        b = 1 - s;
      case 180:
        a = 1 - s;
        b = 1 - t;
      case 270:
        a = 1 - t;
        b = s;
      default:
        a = s;
        b = t;
    }
    final px = pageBox[0] + a * (pageBox[2] - pageBox[0]);
    final py = pageBox[3] - b * (pageBox[3] - pageBox[1]);
    return pageToLatLng(px, py);
  }

  /// Converte coordenadas da página (pontos PDF) em latitude/longitude.
  LatLng pageToLatLng(double px, double py) {
    final aa = affine[0], bb = affine[1], cc = affine[2];
    final dd = affine[3], ee = affine[4], ff = affine[5];
    final det = aa * ee - bb * dd;
    final x = (ee * (px - cc) - bb * (py - ff)) / det;
    final y = (-dd * (px - cc) + aa * (py - ff)) / det;
    if (projection == 'utm') return GeoUtils.fromUtm(utmZone, utmSouth, x, y);
    return LatLng(y.clamp(-90.0, 90.0), x.clamp(-180.0, 180.0));
  }

  Map<String, dynamic> toJson() => {
        'pageIndex': pageIndex,
        'pageBox': pageBox,
        'rotate': rotate,
        'projection': projection,
        'utmZone': utmZone,
        'utmSouth': utmSouth,
        'affine': affine,
        'warnings': warnings,
      };

  factory GeoPdfInfo.fromJson(Map<String, dynamic> j) => GeoPdfInfo(
        pageIndex: j['pageIndex'] as int,
        pageBox: (j['pageBox'] as List).map((e) => (e as num).toDouble()).toList(),
        rotate: j['rotate'] as int,
        projection: j['projection'] as String,
        utmZone: j['utmZone'] as int,
        utmSouth: j['utmSouth'] as bool,
        affine: (j['affine'] as List).map((e) => (e as num).toDouble()).toList(),
        warnings: (j['warnings'] as List).cast<String>(),
      );
}

class GeoPdf {
  GeoPdf._();

  static GeoPdfInfo parseFile(String path) => parseBytes(File(path).readAsBytesSync());

  static GeoPdfInfo parseBytes(List<int> bytes) {
    final text = latin1.decode(bytes);
    final head = text.length > 1024 ? text.substring(0, 1024) : text;
    if (!head.contains('%PDF-')) {
      throw GeoPdfException('O arquivo não é um PDF válido.');
    }
    if (RegExp(r'/Encrypt\s*(\d+\s+\d+\s+R|<<)').hasMatch(text)) {
      throw GeoPdfException('O PDF está protegido por senha ou criptografia. '
          'Exporte uma versão sem proteção.');
    }

    final pdf = PdfFile(text);
    final pages = pdf.pages();

    // Procura a maior janela georreferenciada em todas as páginas.
    int? pageIndex;
    Map? measure;
    List<double>? bbox;
    var bestArea = -1.0;
    for (var i = 0; i < pages.length; i++) {
      final vps = pdf.resolve(pages[i]['VP']);
      if (vps is! List) continue;
      for (final vp in vps) {
        final vd = pdf.dict(vp);
        final m = pdf.dict(vd?['Measure']);
        if (vd == null || m == null || m['Subtype'] != const PdfName('GEO')) continue;
        final b = pdf.numbers(vd['BBox']);
        if (b == null || b.length != 4) continue;
        final area = ((b[2] - b[0]) * (b[3] - b[1])).abs();
        if (area > bestArea) {
          bestArea = area;
          pageIndex = i;
          measure = m;
          bbox = b;
        }
      }
    }

    if (measure == null || bbox == null || pageIndex == null) {
      if (text.contains('/LGIDict')) {
        throw GeoPdfException('Este PDF usa o padrão GeoPDF antigo (TerraGo/OGC), que o app '
            'ainda não lê. Abra-o no QGIS e exporte como "PDF geoespacial" ou gere um .mbtiles.');
      }
      throw GeoPdfException('Este PDF não tem georreferenciamento. No QGIS, use '
          'Projeto › Importar/Exportar › "Exportar mapa para PDF" com a opção '
          '"Incluir informações geoespaciais" marcada.');
    }

    final page = pages[pageIndex];
    final warnings = <String>[];

    // --- Pontos de controle
    final gpts = pdf.numbers(measure['GPTS']);
    final lpts = pdf.numbers(measure['LPTS']) ??
        pdf.numbers(measure['Bounds']) ??
        [0, 0, 0, 1, 1, 1, 1, 0];
    if (gpts == null || gpts.length < 6 || gpts.length.isOdd) {
      throw GeoPdfException('Georreferenciamento incompleto no PDF (GPTS).');
    }
    if (lpts.length != gpts.length) {
      throw GeoPdfException('Georreferenciamento inconsistente no PDF (GPTS × LPTS).');
    }
    // A norma manda latitude primeiro; alguns programas invertem.
    var latFirst = true;
    for (var i = 0; i < gpts.length; i += 2) {
      if (gpts[i].abs() > 90) latFirst = false;
    }

    // --- Sistema de coordenadas
    final gcs = pdf.dict(measure['GCS']);
    final epsgRaw = pdf.resolve(gcs?['EPSG']);
    final epsg = epsgRaw is num ? epsgRaw.toInt() : null;
    final wktRaw = pdf.resolve(gcs?['WKT']);
    final wkt = wktRaw is String ? wktRaw.toUpperCase() : '';

    var projection = 'aprox';
    var zone = 0;
    var south = true;
    final utm = _utmFromEpsg(epsg) ?? _utmFromWkt(wkt);
    if (utm != null) {
      projection = 'utm';
      zone = utm.$1;
      south = utm.$2;
    } else if (const {4326, 4674, 4618, 4225, 4989}.contains(epsg) ||
        wkt.startsWith('GEOGCS') ||
        wkt.startsWith('GEOGCRS')) {
      projection = 'geo';
    } else {
      warnings.add('Projeção do mapa não reconhecida (${epsg != null ? 'EPSG:$epsg' : 'sem código'}). '
          'O posicionamento é aproximado; confira com o GPS em um ponto conhecido.');
    }
    if ((epsg != null && (epsg >= 29100 && epsg < 29200 || epsg == 4618 || epsg == 4225)) ||
        wkt.contains('SAD') ||
        wkt.contains('CORREGO')) {
      warnings.add('Datum antigo (SAD69/Córrego Alegre): pode haver deslocamento de até ~70 m '
          'em relação ao GPS.');
    }

    // --- Pares (projetado → página) e ajuste afim
    final bx0 = math.min(bbox[0], bbox[2]), bx1 = math.max(bbox[0], bbox[2]);
    final by0 = math.min(bbox[1], bbox[3]), by1 = math.max(bbox[1], bbox[3]);
    final src = <List<double>>[];
    final dst = <List<double>>[];
    for (var i = 0; i < gpts.length; i += 2) {
      final lat = latFirst ? gpts[i] : gpts[i + 1];
      final lon = latFirst ? gpts[i + 1] : gpts[i];
      if (projection == 'utm') {
        final u = GeoUtils.toUtm(lat, lon, forceZone: zone, forceSouth: south);
        src.add([u.easting, u.northing]);
      } else {
        src.add([lon, lat]);
      }
      dst.add([bx0 + lpts[i] * (bx1 - bx0), by0 + lpts[i + 1] * (by1 - by0)]);
    }
    final affine = fitAffine(src, dst);

    // Resíduo: mede o quanto os pontos de controle "concordam" entre si.
    var maxRes = 0.0;
    for (var i = 0; i < src.length; i++) {
      final px = affine[0] * src[i][0] + affine[1] * src[i][1] + affine[2];
      final py = affine[3] * src[i][0] + affine[4] * src[i][1] + affine[5];
      maxRes = math.max(maxRes, math.sqrt(math.pow(px - dst[i][0], 2) + math.pow(py - dst[i][1], 2)));
    }
    final diag = math.sqrt(math.pow(bx1 - bx0, 2) + math.pow(by1 - by0, 2));
    if (maxRes > diag * 0.005) {
      warnings.add('Os pontos de controle do PDF não são totalmente consistentes '
          '(diferença de ${(maxRes / diag * 100).toStringAsFixed(1)}% do mapa). '
          'Confira a posição em um ponto conhecido.');
    }

    // --- Caixa e rotação da página
    final box = pdf.numbers(pdf.inherited(page, 'CropBox')) ??
        pdf.numbers(pdf.inherited(page, 'MediaBox')) ??
        [0, 0, 612, 792];
    final pageBox = [
      math.min(box[0], box[2]),
      math.min(box[1], box[3]),
      math.max(box[0], box[2]),
      math.max(box[1], box[3]),
    ];
    final rotRaw = pdf.inherited(page, 'Rotate');
    final rotate = ((rotRaw is num ? rotRaw.toInt() : 0) % 360 + 360) % 360;

    return GeoPdfInfo(
      pageIndex: pageIndex,
      pageBox: pageBox,
      rotate: rotate,
      projection: projection,
      utmZone: zone,
      utmSouth: south,
      affine: affine,
      warnings: warnings,
    );
  }

  /// (zona, sul?) a partir de códigos EPSG de UTM usados no Brasil.
  static (int, bool)? _utmFromEpsg(int? e) {
    if (e == null) return null;
    if (e >= 32701 && e <= 32760) return (e - 32700, true); // WGS84 sul
    if (e >= 32601 && e <= 32660) return (e - 32600, false); // WGS84 norte
    if (e >= 31977 && e <= 31985) return (e - 31960, true); // SIRGAS 2000 sul
    if (e >= 31972 && e <= 31976) return (e - 31955, false); // SIRGAS 2000 norte
    if (e >= 29187 && e <= 29195) return (e - 29170, true); // SAD69 sul
    if (e >= 29168 && e <= 29172) return (e - 29150, false); // SAD69 norte
    return null;
  }

  static (int, bool)? _utmFromWkt(String wkt) {
    if (!(wkt.startsWith('PROJCS') || wkt.startsWith('PROJCRS'))) return null;
    final m = RegExp(r'UTM[ _]ZONE[ _](\d{1,2})\s*([NS])').firstMatch(wkt);
    if (m == null) return null;
    return (int.parse(m.group(1)!), m.group(2) == 'S');
  }

  /// Ajuste afim por mínimos quadrados: dst ≈ A·src + t.
  /// Retorna [a, b, c, d, e, f].
  static List<double> fitAffine(List<List<double>> src, List<List<double>> dst) {
    final n = src.length;
    // Centraliza para evitar perda de precisão com coordenadas UTM grandes.
    var mx = 0.0, my = 0.0;
    for (final p in src) {
      mx += p[0] / n;
      my += p[1] / n;
    }
    final m = List.generate(3, (_) => List<double>.filled(3, 0));
    final rx = List<double>.filled(3, 0);
    final ry = List<double>.filled(3, 0);
    for (var i = 0; i < n; i++) {
      final v = [src[i][0] - mx, src[i][1] - my, 1.0];
      for (var r = 0; r < 3; r++) {
        for (var c = 0; c < 3; c++) {
          m[r][c] += v[r] * v[c];
        }
        rx[r] += v[r] * dst[i][0];
        ry[r] += v[r] * dst[i][1];
      }
    }
    final px = _solve3(m, rx);
    final py = _solve3(m, ry);
    return [
      px[0], px[1], px[2] - px[0] * mx - px[1] * my,
      py[0], py[1], py[2] - py[0] * mx - py[1] * my,
    ];
  }

  static List<double> _solve3(List<List<double>> m0, List<double> r0) {
    final a = [for (var i = 0; i < 3; i++) [...m0[i], r0[i]]];
    for (var col = 0; col < 3; col++) {
      var pivot = col;
      for (var r = col + 1; r < 3; r++) {
        if (a[r][col].abs() > a[pivot][col].abs()) pivot = r;
      }
      if (a[pivot][col].abs() < 1e-12) {
        throw GeoPdfException('Pontos de controle do PDF inválidos (alinhados ou repetidos).');
      }
      final tmp = a[col];
      a[col] = a[pivot];
      a[pivot] = tmp;
      for (var r = 0; r < 3; r++) {
        if (r == col) continue;
        final f = a[r][col] / a[col][col];
        for (var c = col; c < 4; c++) {
          a[r][c] -= f * a[col][c];
        }
      }
    }
    return [for (var i = 0; i < 3; i++) a[i][3] / a[i][i]];
  }
}
