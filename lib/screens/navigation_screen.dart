// Navegação "em linha reta" até um alvo, com bússola.
// Em fiscalização o destino costuma estar fora de estradas (coordenada de um
// alerta, de uma denúncia), então o app mostra distância e direção em vez
// de rota por ruas.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../utils/geo_utils.dart';
import '../theme.dart';

class NavigationScreen extends StatelessWidget {
  const NavigationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final gps = app.myLatLng;
    final target = app.navTarget;
    final pos = app.position;

    return Scaffold(
      appBar: AppBar(title: Text(app.navTargetName ?? 'Bússola')),
      body: StreamBuilder<CompassEvent>(
        stream: FlutterCompass.events,
        builder: (context, snap) {
          // Direção para onde o aparelho aponta: bússola; se não houver,
          // usa o rumo do deslocamento informado pelo GPS.
          double? heading = snap.data?.heading;
          if (heading == null && pos != null && pos.speed > 1) heading = pos.heading;

          final dist =
              (gps != null && target != null) ? GeoUtils.distance(gps, target) : null;
          final bearing =
              (gps != null && target != null) ? GeoUtils.bearing(gps, target) : null;
          final arrived = dist != null && dist <= math.max(10, pos?.accuracy ?? 10);

          // Ângulo da seta: rumo ao alvo menos a direção do aparelho.
          final arrowDeg = bearing == null ? 0.0 : bearing - (heading ?? 0);

          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              if (target == null)
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: Text(
                    'Nenhum destino definido. No mapa, toque e segure um local '
                    '(ou abra um ponto) e escolha "Navegar".',
                    textAlign: TextAlign.center,
                  ),
                ),
              Center(
                child: SizedBox(
                  width: 260,
                  height: 260,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Rosa dos ventos (gira com a bússola)
                      Transform.rotate(
                        angle: -(heading ?? 0) * math.pi / 180,
                        child: const _CompassRose(),
                      ),
                      if (bearing != null)
                        Transform.rotate(
                          angle: arrowDeg * math.pi / 180,
                          child: Icon(
                            arrived ? Icons.where_to_vote : Icons.navigation,
                            size: 110,
                            color: arrived ? Colors.green : AppColors.primary,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              if (arrived)
                const Text('Você chegou ao destino',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 22, color: Colors.green, fontWeight: FontWeight.bold)),
              if (dist != null && !arrived)
                Text(GeoUtils.formatDistance(dist),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.displaySmall),
              if (bearing != null)
                Text('Rumo ${bearing.toStringAsFixed(0)}° (${GeoUtils.cardinal(bearing)})',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              _InfoRow('Direção do aparelho',
                  heading == null ? 'indisponível' : '${((heading + 360) % 360).toStringAsFixed(0)}°'),
              _InfoRow('Minha posição', gps == null ? 'aguardando GPS' : GeoUtils.format(gps, app.coordFormat)),
              if (pos != null) _InfoRow('Precisão do GPS', '±${pos.accuracy.toStringAsFixed(0)} m'),
              if (pos != null) _InfoRow('Altitude', '${pos.altitude.toStringAsFixed(0)} m'),
              if (target != null) _InfoRow('Destino', GeoUtils.format(target, app.coordFormat)),
              const SizedBox(height: 16),
              const Text(
                'Para uma bússola precisa, segure o celular na horizontal, longe de '
                'veículos e objetos metálicos. Se necessário, calibre movendo o '
                'aparelho em forma de "8".',
                style: TextStyle(fontSize: 12),
                textAlign: TextAlign.center,
              ),
              if (target != null) ...[
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () {
                    app.clearNavTarget();
                    Navigator.pop(context);
                  },
                  icon: const Icon(Icons.close),
                  label: const Text('Encerrar navegação'),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 150, child: Text(label, style: const TextStyle(color: Colors.black54))),
          Expanded(child: Text(value, style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]))),
        ],
      ),
    );
  }
}

class _CompassRose extends StatelessWidget {
  const _CompassRose();

  @override
  Widget build(BuildContext context) {
    const labels = {'N': 0.0, 'L': 90.0, 'S': 180.0, 'O': 270.0};
    return Container(
      width: 260,
      height: 260,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.grey.shade400, width: 2),
        color: Colors.grey.shade100,
      ),
      child: Stack(
        children: [
          for (final e in labels.entries)
            Align(
              alignment: Alignment(
                math.sin(e.value * math.pi / 180) * 0.85,
                -math.cos(e.value * math.pi / 180) * 0.85,
              ),
              child: Text(
                e.key,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: e.key == 'N' ? Colors.red : Colors.black87,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
