import 'package:flutter/material.dart';

/// Cor e ícone de cada categoria de ponto de fiscalização.
class CategoryStyle {
  CategoryStyle._();

  static Color color(String category) => switch (category) {
        'Desmatamento' => const Color(0xFF6D4C41),
        'Queimada' => const Color(0xFFE53935),
        'Fauna' => const Color(0xFF43A047),
        'Pesca' => const Color(0xFF1E88E5),
        'Mineração' => const Color(0xFFFFB300),
        'Embargo' => const Color(0xFF8E24AA),
        'Infraestrutura' => const Color(0xFF546E7A),
        _ => const Color(0xFF00897B),
      };

  static IconData icon(String category) => switch (category) {
        'Desmatamento' => Icons.forest,
        'Queimada' => Icons.local_fire_department,
        'Fauna' => Icons.pets,
        'Pesca' => Icons.phishing,
        'Mineração' => Icons.landscape,
        'Embargo' => Icons.block,
        'Infraestrutura' => Icons.construction,
        _ => Icons.place,
      };
}
