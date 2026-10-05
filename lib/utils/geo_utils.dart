// Funções geográficas usadas em todo o app:
//  - conversão entre coordenadas geográficas e UTM (SIRGAS 2000 / GRS80)
//  - formatação em graus decimais, graus-minutos-segundos (GMS) e UTM
//  - leitura de coordenadas digitadas pelo usuário
//  - distância, rumo (azimute) e teste "ponto dentro de polígono"
//
// Tudo aqui é Dart puro (sem Flutter), o que facilita os testes unitários.

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Formatos de exibição de coordenadas.
enum CoordFormat {
  decimal('Graus decimais'),
  dms('Graus, minutos e segundos'),
  utm('UTM (SIRGAS 2000)');

  const CoordFormat(this.label);
  final String label;
}

/// Coordenada UTM. [band] é a letra da faixa de latitude (C..X).
/// Faixas menores que 'N' ficam no hemisfério sul.
class UtmCoord {
  const UtmCoord(this.zone, this.band, this.easting, this.northing);

  final int zone;
  final String band;
  final double easting;
  final double northing;

  bool get south => band.compareTo('N') < 0;

  @override
  String toString() =>
      '$zone$band ${easting.toStringAsFixed(0)}E ${northing.toStringAsFixed(0)}N';
}

class GeoUtils {
  GeoUtils._();

  // Elipsoide GRS80 (usado pelo SIRGAS 2000). A diferença para o WGS84
  // (usado pelo GPS) é de milímetros, desprezível em campo.
  static const double _a = 6378137.0;
  static const double _f = 1 / 298.257222101;
  static const double _k0 = 0.9996;
  static const double _e2 = _f * (2 - _f);
  static const double _ep2 = _e2 / (1 - _e2);
  static const String _bands = 'CDEFGHJKLMNPQRSTUVWX';
  static const double earthRadius = 6371008.8; // raio médio (m)

  static double _rad(double d) => d * math.pi / 180;
  static double _deg(double r) => r * 180 / math.pi;

  // ---------------------------------------------------------------- UTM

  static int zoneFor(double lon) => ((lon + 180) / 6).floor().clamp(0, 59) + 1;

  static String bandFor(double lat) {
    final idx = ((lat + 80) / 8).floor().clamp(0, 19);
    return _bands[idx];
  }

  /// Converte latitude/longitude (graus) para UTM.
  /// [forceZone] e [forceSouth] permitem calcular numa zona/hemisfério fixos
  /// (ex.: um mapa inteiro em UTM 21S, mesmo com trechos acima do Equador).
  static UtmCoord toUtm(double lat, double lon, {int? forceZone, bool? forceSouth}) {
    final zone = forceZone ?? zoneFor(lon);
    final lon0 = _rad((zone - 1) * 6 - 180 + 3.0);
    final phi = _rad(lat);
    final lambda = _rad(lon);

    final sinPhi = math.sin(phi);
    final cosPhi = math.cos(phi);
    final tanPhi = math.tan(phi);

    final n = _a / math.sqrt(1 - _e2 * sinPhi * sinPhi);
    final t = tanPhi * tanPhi;
    final c = _ep2 * cosPhi * cosPhi;
    final a = cosPhi * (lambda - lon0);

    final e4 = _e2 * _e2;
    final e6 = e4 * _e2;
    final m = _a *
        ((1 - _e2 / 4 - 3 * e4 / 64 - 5 * e6 / 256) * phi -
            (3 * _e2 / 8 + 3 * e4 / 32 + 45 * e6 / 1024) * math.sin(2 * phi) +
            (15 * e4 / 256 + 45 * e6 / 1024) * math.sin(4 * phi) -
            (35 * e6 / 3072) * math.sin(6 * phi));

    final a2 = a * a, a3 = a2 * a, a4 = a3 * a, a5 = a4 * a, a6 = a5 * a;

    final easting = _k0 *
            n *
            (a +
                (1 - t + c) * a3 / 6 +
                (5 - 18 * t + t * t + 72 * c - 58 * _ep2) * a5 / 120) +
        500000.0;
    var northing = _k0 *
        (m +
            n *
                tanPhi *
                (a2 / 2 +
                    (5 - t + 9 * c + 4 * c * c) * a4 / 24 +
                    (61 - 58 * t + t * t + 600 * c - 330 * _ep2) * a6 / 720));
    if (forceSouth ?? lat < 0) northing += 10000000.0;

    return UtmCoord(zone, bandFor(lat), easting, northing);
  }

  /// Converte UTM para latitude/longitude (graus).
  static LatLng fromUtm(int zone, bool south, double easting, double northing) {
    final x = easting - 500000.0;
    final y = south ? northing - 10000000.0 : northing;
    final lon0 = _rad((zone - 1) * 6 - 180 + 3.0);

    final e4 = _e2 * _e2;
    final e6 = e4 * _e2;
    final m = y / _k0;
    final mu = m / (_a * (1 - _e2 / 4 - 3 * e4 / 64 - 5 * e6 / 256));
    final sq = math.sqrt(1 - _e2);
    final e1 = (1 - sq) / (1 + sq);

    final phi1 = mu +
        (3 * e1 / 2 - 27 * math.pow(e1, 3) / 32) * math.sin(2 * mu) +
        (21 * e1 * e1 / 16 - 55 * math.pow(e1, 4) / 32) * math.sin(4 * mu) +
        (151 * math.pow(e1, 3) / 96) * math.sin(6 * mu) +
        (1097 * math.pow(e1, 4) / 512) * math.sin(8 * mu);

    final sin1 = math.sin(phi1);
    final cos1 = math.cos(phi1);
    final tan1 = math.tan(phi1);
    final n1 = _a / math.sqrt(1 - _e2 * sin1 * sin1);
    final t1 = tan1 * tan1;
    final c1 = _ep2 * cos1 * cos1;
    final r1 = _a * (1 - _e2) / math.pow(1 - _e2 * sin1 * sin1, 1.5);
    final d = x / (n1 * _k0);
    final d2 = d * d, d3 = d2 * d, d4 = d3 * d, d5 = d4 * d, d6 = d5 * d;

    final lat = phi1 -
        (n1 * tan1 / r1) *
            (d2 / 2 -
                (5 + 3 * t1 + 10 * c1 - 4 * c1 * c1 - 9 * _ep2) * d4 / 24 +
                (61 + 90 * t1 + 298 * c1 + 45 * t1 * t1 - 252 * _ep2 - 3 * c1 * c1) *
                    d6 /
                    720);
    final lon = lon0 +
        (d -
                (1 + 2 * t1 + c1) * d3 / 6 +
                (5 - 2 * c1 + 28 * t1 - 3 * c1 * c1 + 8 * _ep2 + 24 * t1 * t1) *
                    d5 /
                    120) /
            cos1;

    return LatLng(_deg(lat), _deg(lon));
  }

  // --------------------------------------------------------- Formatação

  /// Ex.: -3.5 (latitude) -> 3°30'00.00" S
  static String toDms(double value, {required bool isLat}) {
    final hemi = isLat ? (value < 0 ? 'S' : 'N') : (value < 0 ? 'W' : 'E');
    final v = value.abs();
    var d = v.floor();
    final minutesFull = (v - d) * 60;
    var m = minutesFull.floor();
    var s = double.parse(((minutesFull - m) * 60).toStringAsFixed(2));
    if (s >= 60) {
      s -= 60;
      m += 1;
    }
    if (m >= 60) {
      m -= 60;
      d += 1;
    }
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toStringAsFixed(2).padLeft(5, '0');
    return '$d°$mm\'$ss" $hemi';
  }

  static String format(LatLng p, CoordFormat f) {
    switch (f) {
      case CoordFormat.decimal:
        return '${p.latitude.toStringAsFixed(6)}, ${p.longitude.toStringAsFixed(6)}';
      case CoordFormat.dms:
        return '${toDms(p.latitude, isLat: true)}  ${toDms(p.longitude, isLat: false)}';
      case CoordFormat.utm:
        return toUtm(p.latitude, p.longitude).toString();
    }
  }

  static String formatDistance(double meters) {
    if (meters < 1000) return '${meters.toStringAsFixed(0)} m';
    return '${(meters / 1000).toStringAsFixed(meters < 10000 ? 2 : 1).replaceAll('.', ',')} km';
  }

  static String cardinal(double bearing) {
    const names = ['N', 'NE', 'L', 'SE', 'S', 'SO', 'O', 'NO'];
    return names[((bearing % 360) / 45).round() % 8];
  }

  // ------------------------------------------------------------ Leitura

  static double _num(String s) => double.parse(s.replaceAll(',', '.'));

  static bool _valid(double lat, double lon) =>
      lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180;

  /// Interpreta uma coordenada digitada. Aceita:
  ///  - decimal:   -3.4567, -60.1234   |  -3,4567; -60,1234
  ///  - GMS:       3°27'24"S 60°07'24"W  (W/O = oeste, E/L = leste)
  ///  - UTM:       20M 815000 9617000    (zona + letra da faixa)
  /// Retorna null se não conseguir interpretar.
  static LatLng? parse(String input) {
    final s = input.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (s.isEmpty) return null;

    // UTM
    final utm = RegExp(
      r'^(\d{1,2}) ?([C-HJ-NP-X]) (\d+(?:[.,]\d+)?) ?E? (\d+(?:[.,]\d+)?) ?N?$',
      caseSensitive: false,
    ).firstMatch(s);
    if (utm != null) {
      final zone = int.parse(utm.group(1)!);
      final band = utm.group(2)!.toUpperCase();
      final e = _num(utm.group(3)!);
      final n = _num(utm.group(4)!);
      if (zone < 1 || zone > 60) return null;
      if (e < 100000 || e > 900000 || n < 0 || n > 10000000) return null;
      return fromUtm(zone, band.compareTo('N') < 0, e, n);
    }

    // Graus, minutos e segundos
    final dms = RegExp(
      r'''^(\d{1,3})[°º ]\s?(\d{1,2})['’ ]\s?(\d{1,2}(?:[.,]\d+)?)["”]?\s?([NS])[ ,;]+(\d{1,3})[°º ]\s?(\d{1,2})['’ ]\s?(\d{1,2}(?:[.,]\d+)?)["”]?\s?([EWLO])$''',
      caseSensitive: false,
    ).firstMatch(s);
    if (dms != null) {
      var lat = int.parse(dms.group(1)!) +
          int.parse(dms.group(2)!) / 60 +
          _num(dms.group(3)!) / 3600;
      var lon = int.parse(dms.group(5)!) +
          int.parse(dms.group(6)!) / 60 +
          _num(dms.group(7)!) / 3600;
      if (dms.group(4)!.toUpperCase() == 'S') lat = -lat;
      final h = dms.group(8)!.toUpperCase();
      if (h == 'W' || h == 'O') lon = -lon;
      return _valid(lat, lon) ? LatLng(lat, lon) : null;
    }

    // Decimal: separador ";" (aceita vírgula decimal) ...
    if (s.contains(';')) {
      final parts = s.split(';');
      if (parts.length == 2) {
        final lat = double.tryParse(parts[0].trim().replaceAll(',', '.'));
        final lon = double.tryParse(parts[1].trim().replaceAll(',', '.'));
        if (lat != null && lon != null && _valid(lat, lon)) return LatLng(lat, lon);
      }
      return null;
    }
    // ... ponto decimal com vírgula ou espaço separando ...
    final dec = RegExp(r'^(-?\d+(?:\.\d+)?) ?[, ] ?(-?\d+(?:\.\d+)?)$').firstMatch(s);
    if (dec != null) {
      final lat = double.parse(dec.group(1)!);
      final lon = double.parse(dec.group(2)!);
      return _valid(lat, lon) ? LatLng(lat, lon) : null;
    }
    // ... ou vírgula decimal separada por espaço.
    final decBr = RegExp(r'^(-?\d+(?:,\d+)?) (-?\d+(?:,\d+)?)$').firstMatch(s);
    if (decBr != null) {
      final lat = _num(decBr.group(1)!);
      final lon = _num(decBr.group(2)!);
      return _valid(lat, lon) ? LatLng(lat, lon) : null;
    }
    return null;
  }

  // ------------------------------------------------- Distância e rumo

  /// Distância em metros (fórmula de haversine).
  static double distance(LatLng a, LatLng b) {
    final dLat = _rad(b.latitude - a.latitude);
    final dLon = _rad(b.longitude - a.longitude);
    final h = math.pow(math.sin(dLat / 2), 2) +
        math.cos(_rad(a.latitude)) *
            math.cos(_rad(b.latitude)) *
            math.pow(math.sin(dLon / 2), 2);
    return 2 * earthRadius * math.asin(math.min(1, math.sqrt(h)));
  }

  /// Rumo (azimute) inicial de [a] para [b], de 0 a 360 graus (0 = norte).
  static double bearing(LatLng a, LatLng b) {
    final phi1 = _rad(a.latitude), phi2 = _rad(b.latitude);
    final dLon = _rad(b.longitude - a.longitude);
    final y = math.sin(dLon) * math.cos(phi2);
    final x = math.cos(phi1) * math.sin(phi2) -
        math.sin(phi1) * math.cos(phi2) * math.cos(dLon);
    return (_deg(math.atan2(y, x)) + 360) % 360;
  }

  static double pathLength(List<LatLng> pts) {
    var total = 0.0;
    for (var i = 1; i < pts.length; i++) {
      total += distance(pts[i - 1], pts[i]);
    }
    return total;
  }

  /// Teste de ponto dentro de anel (algoritmo de ray casting).
  static bool pointInRing(LatLng p, List<LatLng> ring) {
    var inside = false;
    for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      final xi = ring[i].longitude, yi = ring[i].latitude;
      final xj = ring[j].longitude, yj = ring[j].latitude;
      final intersect = ((yi > p.latitude) != (yj > p.latitude)) &&
          (p.longitude < (xj - xi) * (p.latitude - yi) / (yj - yi) + xi);
      if (intersect) inside = !inside;
    }
    return inside;
  }
}
