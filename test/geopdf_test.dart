import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verdemap/services/formats/geopdf.dart';
import 'package:verdemap/utils/geo_utils.dart';
import 'package:latlong2/latlong.dart';

/// Monta um PDF mínimo (sem desenho) com uma janela georreferenciada
/// na área [100 100 900 700] de uma página 1000 × 800.
List<int> _pdf({required String gpts, required String gcs, int rotate = 0}) => latin1.encode('''%PDF-1.7
1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 1000 800] >> endobj
3 0 obj << /Type /Page /Parent 2 0 R /Rotate $rotate
  /VP [ << /Type /Viewport /BBox [100 100 900 700] /Measure 4 0 R >> ] >> endobj
4 0 obj << /Type /Measure /Subtype /GEO /Bounds [0 0 0 1 1 1 1 0]
  /GPTS [$gpts] /LPTS [0 0 0 1 1 1 1 0] /GCS 5 0 R >> endobj
5 0 obj $gcs endobj
trailer << /Root 1 0 R >>
%%EOF
''');

double _dist(LatLng a, LatLng b) => GeoUtils.distance(a, b);

void main() {
  test('PDF geográfico (SIRGAS 2000): centro e canto da janela', () {
    final info = GeoPdf.parseBytes(_pdf(
      gpts: '-10 -50 -9 -50 -9 -49 -10 -49',
      gcs: '<< /Type /GEOGCS /EPSG 4674 >>',
    ));
    expect(info.projection, 'geo');
    // centro da página = centro da janela
    expect(_dist(info.normToLatLng(0.5, 0.5), const LatLng(-9.5, -49.5)), lessThan(0.5));
    // canto superior esquerdo da janela: x=100, y=700 → s=0.1, t=0.125
    expect(_dist(info.normToLatLng(0.1, 0.125), const LatLng(-9, -50)), lessThan(0.5));
  });

  test('PDF em UTM 23S (EPSG:31983): posição exata dentro do mapa', () {
    final info = GeoPdf.parseBytes(_pdf(
      // cantos E 200000–210000, N 8250000–8260000 convertidos para lat/long
      gpts: '-15.810745990 -47.800381266 -15.720448450 -47.799142269 '
          '-15.721624808 -47.705913682 -15.811929447 -47.707111538',
      gcs: '<< /Type /PROJCS /EPSG 31983 >>',
    ));
    expect(info.projection, 'utm');
    expect(info.utmZone, 23);
    expect(info.utmSouth, isTrue);
    // E 205000 N 8255000 (centro)
    expect(_dist(info.pageToLatLng(500, 400),
            const LatLng(-15.766192259438194, -47.753137188624045)),
        lessThan(0.5));
    // E 202500 N 8257500 (u = 0.25, v = 0.75 → página 300, 550)
    expect(_dist(info.pageToLatLng(300, 550),
            const LatLng(-15.743321176658869, -47.776142295771166)),
        lessThan(0.5));
  });

  test('Página girada 90°', () {
    final info = GeoPdf.parseBytes(_pdf(
      gpts: '-10 -50 -9 -50 -9 -49 -10 -49',
      gcs: '<< /Type /GEOGCS /EPSG 4326 >>',
      rotate: 90,
    ));
    expect(info.rotate, 90);
    expect(info.aspect, closeTo(800 / 1000, 1e-9));
    expect(_dist(info.normToLatLng(0.875, 0.1), const LatLng(-9, -50)), lessThan(0.5));
  });

  test('Objetos dentro de object stream compactado (PDF 1.5+)', () {
    const obj4 = '<< /Type /Measure /Subtype /GEO /GPTS [-10 -50 -9 -50 -9 -49 -10 -49] '
        '/LPTS [0 0 0 1 1 1 1 0] /GCS 5 0 R >>';
    const obj5 = '<< /Type /GEOGCS /EPSG 4674 >>';
    // Cabeçalho do object stream: "nº_objeto deslocamento" para cada objeto
    final fixedHeader = '4 0 5 ${obj4.length + 1} ';
    final fixedBody = '$fixedHeader$obj4 $obj5';
    final fixedFirst = fixedHeader.length;
    final compressed = ZLibEncoder().encode(latin1.encode(fixedBody));

    final bytes = <int>[
      ...latin1.encode('%PDF-1.7\n'
          '1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n'
          '2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\n'
          '3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 1000 800] '
          '/VP [ << /BBox [100 100 900 700] /Measure 4 0 R >> ] >> endobj\n'
          '6 0 obj << /Type /ObjStm /N 2 /First $fixedFirst /Filter /FlateDecode '
          '/Length ${compressed.length} >>\nstream\n'),
      ...compressed,
      ...latin1.encode('\nendstream\nendobj\n%%EOF\n'),
    ];
    final info = GeoPdf.parseBytes(bytes);
    expect(info.projection, 'geo');
    expect(_dist(info.normToLatLng(0.5, 0.5), const LatLng(-9.5, -49.5)), lessThan(0.5));
  });

  test('PDF sem georreferenciamento gera erro explicativo', () {
    final plain = latin1.encode('%PDF-1.4\n'
        '1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n'
        '2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\n'
        '3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] >> endobj\n%%EOF');
    expect(() => GeoPdf.parseBytes(plain), throwsA(isA<GeoPdfException>()));
  });
}
