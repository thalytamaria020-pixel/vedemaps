import 'package:flutter_test/flutter_test.dart';
import 'package:verdemap/utils/geo_utils.dart';
import 'package:latlong2/latlong.dart';

void main() {
  group('UTM', () {
    test('Brasília -> UTM 23L (conferido com a série de Krüger/Karney)', () {
      final u = GeoUtils.toUtm(-15.7939, -47.8828);
      expect(u.zone, 23);
      expect(u.band, 'L');
      expect(u.easting, closeTo(191138.743, 0.01));
      expect(u.northing, closeTo(8251745.906, 0.01));
    });

    test('ida e volta UTM -> geográfica preserva a posição (< 1 cm)', () {
      for (final p in const [
        LatLng(-3.1190, -60.0217), // Manaus
        LatLng(-10.1689, -48.3317), // Palmas
        LatLng(2.8235, -60.6758), // Boa Vista (hemisfério norte)
        LatLng(-29.6842, -53.8069), // Santa Maria
      ]) {
        final u = GeoUtils.toUtm(p.latitude, p.longitude);
        final back = GeoUtils.fromUtm(u.zone, u.south, u.easting, u.northing);
        expect(GeoUtils.distance(p, back), lessThan(0.01));
      }
    });
  });

  group('Leitura de coordenadas', () {
    test('decimal com ponto', () {
      final p = GeoUtils.parse('-3.4567, -60.1234')!;
      expect(p.latitude, closeTo(-3.4567, 1e-9));
      expect(p.longitude, closeTo(-60.1234, 1e-9));
    });

    test('decimal com vírgula e ponto e vírgula', () {
      final p = GeoUtils.parse('-3,4567; -60,1234')!;
      expect(p.latitude, closeTo(-3.4567, 1e-9));
    });

    test('graus, minutos e segundos (W e O)', () {
      final a = GeoUtils.parse('3°27\'24"S 60°07\'24"W')!;
      final b = GeoUtils.parse('3°27\'24"S 60°07\'24"O')!;
      expect(a.latitude, closeTo(-3.456667, 1e-5));
      expect(a.longitude, closeTo(-60.123333, 1e-5));
      expect(b.longitude, a.longitude);
    });

    test('UTM', () {
      final p = GeoUtils.parse('23L 191139 8251746')!;
      expect(GeoUtils.distance(p, const LatLng(-15.7939, -47.8828)), lessThan(2));
    });

    test('entrada inválida retorna null', () {
      expect(GeoUtils.parse('abc'), isNull);
      expect(GeoUtils.parse('-95, 10'), isNull);
    });
  });

  group('Distância, rumo e formatação', () {
    test('1 grau de latitude ~ 111 km', () {
      final d = GeoUtils.distance(const LatLng(0, 0), const LatLng(1, 0));
      expect(d, closeTo(111195, 50));
    });

    test('rumo leste = 90°', () {
      expect(GeoUtils.bearing(const LatLng(0, 0), const LatLng(0, 1)), closeTo(90, 1e-6));
    });

    test('GMS', () {
      expect(GeoUtils.toDms(-3.5, isLat: true), '3°30\'00.00" S');
    });

    test('ponto dentro de polígono', () {
      const ring = [LatLng(0, 0), LatLng(0, 1), LatLng(1, 1), LatLng(1, 0)];
      expect(GeoUtils.pointInRing(const LatLng(0.5, 0.5), ring), isTrue);
      expect(GeoUtils.pointInRing(const LatLng(1.5, 0.5), ring), isFalse);
    });
  });
}
