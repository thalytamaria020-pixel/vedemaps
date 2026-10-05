import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

import '../services/geopdf_service.dart';

/// Desenha os mapas PDF visíveis sobre o mapa base.
/// Afastado: usa os blocos da visão geral. Aproximado: só os blocos de
/// detalhe que estão na tela (economiza memória do celular).
class GeoPdfLayer extends StatelessWidget {
  const GeoPdfLayer({super.key, required this.maps});

  final List<GeoPdfMap> maps;

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final view = camera.visibleBounds;
    final overlays = <BaseOverlayImage>[];

    for (final m in maps) {
      if (!m.visible || !view.isOverlapping(m.bounds)) continue;
      final useDetail = camera.zoom > m.switchZoom;
      for (final c in useDetail ? m.detail : m.overview) {
        if (useDetail && !view.isOverlapping(c.bounds)) continue;
        overlays.add(RotatedOverlayImage(
          topLeftCorner: c.topLeft,
          bottomLeftCorner: c.bottomLeft,
          bottomRightCorner: c.bottomRight,
          opacity: m.opacity,
          gaplessPlayback: true,
          imageProvider: FileImage(File(m.path(c))),
        ));
      }
    }
    return OverlayImageLayer(overlayImages: overlays);
  }
}
