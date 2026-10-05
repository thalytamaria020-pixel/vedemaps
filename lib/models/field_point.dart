import 'dart:convert';

import 'package:latlong2/latlong.dart';

/// Ponto registrado em campo (uma ocorrência de fiscalização).
class FieldPoint {
  const FieldPoint({
    this.id,
    required this.latitude,
    required this.longitude,
    this.altitude,
    this.accuracy,
    required this.createdAt,
    required this.category,
    required this.title,
    this.notes = '',
    this.photos = const [],
  });

  final int? id;
  final double latitude;
  final double longitude;
  final double? altitude; // metros
  final double? accuracy; // precisão horizontal do GPS, em metros
  final DateTime createdAt;
  final String category;
  final String title;
  final String notes;

  /// Nomes dos arquivos de foto (salvos na pasta "fotos" do app).
  /// Guardamos só o nome, e não o caminho completo, porque no iOS o caminho
  /// da pasta do app muda a cada atualização.
  final List<String> photos;

  static const categories = [
    'Desmatamento',
    'Queimada',
    'Fauna',
    'Pesca',
    'Mineração',
    'Embargo',
    'Infraestrutura',
    'Outro',
  ];

  LatLng get latLng => LatLng(latitude, longitude);

  FieldPoint copyWith({
    int? id,
    double? latitude,
    double? longitude,
    String? category,
    String? title,
    String? notes,
    List<String>? photos,
  }) =>
      FieldPoint(
        id: id ?? this.id,
        latitude: latitude ?? this.latitude,
        longitude: longitude ?? this.longitude,
        altitude: altitude,
        accuracy: accuracy,
        createdAt: createdAt,
        category: category ?? this.category,
        title: title ?? this.title,
        notes: notes ?? this.notes,
        photos: photos ?? this.photos,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'latitude': latitude,
        'longitude': longitude,
        'altitude': altitude,
        'accuracy': accuracy,
        'created_at': createdAt.toIso8601String(),
        'category': category,
        'title': title,
        'notes': notes,
        'photos': jsonEncode(photos),
      };

  factory FieldPoint.fromMap(Map<String, Object?> m) => FieldPoint(
        id: m['id'] as int?,
        latitude: (m['latitude'] as num).toDouble(),
        longitude: (m['longitude'] as num).toDouble(),
        altitude: (m['altitude'] as num?)?.toDouble(),
        accuracy: (m['accuracy'] as num?)?.toDouble(),
        createdAt: DateTime.parse(m['created_at'] as String),
        category: m['category'] as String,
        title: m['title'] as String,
        notes: (m['notes'] as String?) ?? '',
        photos: (jsonDecode((m['photos'] as String?) ?? '[]') as List)
            .cast<String>(),
      );
}
