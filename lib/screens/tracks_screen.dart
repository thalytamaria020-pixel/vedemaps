// Lista de trilhas gravadas: exibir no mapa, exportar (GPX/KML), renomear, excluir.

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:provider/provider.dart';

import '../models/track.dart';
import '../services/export_service.dart';
import '../state/app_state.dart';
import '../utils/geo_utils.dart';

class TracksScreen extends StatelessWidget {
  const TracksScreen({super.key});

  static String _dur(Duration d) =>
      d.inHours > 0 ? '${d.inHours}h${(d.inMinutes % 60).toString().padLeft(2, '0')}' : '${d.inMinutes} min';

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final tracks = app.tracks;

    return Scaffold(
      appBar: AppBar(title: Text('Trilhas (${tracks.length})')),
      body: tracks.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Nenhuma trilha gravada.\nUse o botão de trilha no mapa para começar.',
                    textAlign: TextAlign.center),
              ),
            )
          : ListView.separated(
              itemCount: tracks.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final t = tracks[i];
                final isRecording = app.recording?.id == t.id;
                return ListTile(
                  leading: Switch(
                    value: app.visibleTracks.containsKey(t.id),
                    onChanged: isRecording ? null : (_) => app.toggleTrackVisible(t),
                  ),
                  title: Text(t.name),
                  subtitle: Text(isRecording
                      ? 'Gravando agora...'
                      : '${ExportService.formatDateTime(t.startedAt)} · '
                          '${GeoUtils.formatDistance(t.distanceMeters)} · ${_dur(t.duration)} · '
                          '${t.pointCount} pts'),
                  trailing: isRecording
                      ? const Icon(Icons.fiber_manual_record, color: Colors.red)
                      : PopupMenuButton<String>(
                          onSelected: (a) => _action(context, app, t, a),
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'zoom', child: Text('Ver no mapa')),
                            PopupMenuItem(value: 'gpx', child: Text('Exportar GPX')),
                            PopupMenuItem(value: 'kml', child: Text('Exportar KML')),
                            PopupMenuItem(value: 'rename', child: Text('Renomear')),
                            PopupMenuItem(value: 'delete', child: Text('Excluir')),
                          ],
                        ),
                );
              },
            ),
    );
  }

  Future<void> _action(BuildContext context, AppState app, Track t, String action) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    switch (action) {
      case 'zoom':
        final zoomPts = await app.trackPoints(t);
        if (zoomPts.length < 2) {
          messenger.showSnackBar(const SnackBar(content: Text('Trilha sem pontos suficientes.')));
          return;
        }
        if (!app.visibleTracks.containsKey(t.id)) await app.toggleTrackVisible(t);
        navigator.pop(LatLngBounds.fromPoints(zoomPts.map((e) => e.latLng).toList()));
      case 'gpx':
      case 'kml':
        final pts = await app.trackPoints(t);
        final safe = t.name.replaceAll(RegExp(r'[^\w\-]+'), '_');
        final file = await ExportService.writeText(
          '$safe.$action',
          action == 'gpx' ? ExportService.trackToGpx(t, pts) : ExportService.trackToKml(t, pts),
        );
        await ExportService.share([file], text: t.name);
      case 'rename':
        if (!context.mounted) return;
        final controller = TextEditingController(text: t.name);
        final name = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Renomear trilha'),
            content: TextField(controller: controller, autofocus: true),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                  child: const Text('Salvar')),
            ],
          ),
        );
        if (name != null && name.isNotEmpty) await app.renameTrack(t, name);
      case 'delete':
        if (!context.mounted) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Excluir trilha?'),
            content: Text('"${t.name}" será apagada deste aparelho.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Excluir')),
            ],
          ),
        );
        if (ok == true) await app.deleteTrack(t);
    }
  }
}
