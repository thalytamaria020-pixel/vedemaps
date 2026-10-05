import 'package:latlong2/latlong.dart';

/// Trilha (percurso) gravada pelo GPS.
class Track {
  const Track({
    this.id,
    required this.name,
    required this.startedAt,
    this.endedAt,
    this.distanceMeters = 0,
    this.pointCount = 0,
  });

  final int? id;
  final String name;
  final DateTime startedAt;
  final DateTime? endedAt;
  final double distanceMeters;
  final int pointCount; // calculado na consulta, não é gravado

  Duration get duration => (endedAt ?? DateTime.now()).difference(startedAt);

  Track copyWith({
    int? id,
    String? name,
    DateTime? endedAt,
    double? distanceMeters,
    int? pointCount,
  }) =>
      Track(
        id: id ?? this.id,
        name: name ?? this.name,
        startedAt: startedAt,
        endedAt: endedAt ?? this.endedAt,
        distanceMeters: distanceMeters ?? this.distanceMeters,
        pointCount: pointCount ?? this.pointCount,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'started_at': startedAt.toIso8601String(),
        'ended_at': endedAt?.toIso8601String(),
        'distance_m': distanceMeters,
      };

  factory Track.fromMap(Map<String, Object?> m) => Track(
        id: m['id'] as int?,
        name: m['name'] as String,
        startedAt: DateTime.parse(m['started_at'] as String),
        endedAt: m['ended_at'] == null
            ? null
            : DateTime.parse(m['ended_at'] as String),
        distanceMeters: (m['distance_m'] as num?)?.toDouble() ?? 0,
        pointCount: (m['point_count'] as int?) ?? 0,
      );
}

/// Um ponto (vértice) de uma trilha.
class TrackPoint {
  const TrackPoint({
    required this.latitude,
    required this.longitude,
    this.altitude,
    this.accuracy,
    this.speed,
    required this.time,
  });

  final double latitude;
  final double longitude;
  final double? altitude;
  final double? accuracy;
  final double? speed; // m/s
  final DateTime time;

  LatLng get latLng => LatLng(latitude, longitude);

  Map<String, Object?> toMap(int trackId) => {
        'track_id': trackId,
        'latitude': latitude,
        'longitude': longitude,
        'altitude': altitude,
        'accuracy': accuracy,
        'speed': speed,
        'time': time.toIso8601String(),
      };

  factory TrackPoint.fromMap(Map<String, Object?> m) => TrackPoint(
        latitude: (m['latitude'] as num).toDouble(),
        longitude: (m['longitude'] as num).toDouble(),
        altitude: (m['altitude'] as num?)?.toDouble(),
        accuracy: (m['accuracy'] as num?)?.toDouble(),
        speed: (m['speed'] as num?)?.toDouble(),
        time: DateTime.parse(m['time'] as String),
      );
}
