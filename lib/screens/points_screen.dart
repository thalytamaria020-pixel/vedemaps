// Lista de pontos registrados, com filtro por categoria e exportação.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/field_point.dart';
import '../models/track.dart';
import '../services/export_service.dart';
import '../state/app_state.dart';
import '../utils/geo_utils.dart';
import '../widgets/category_style.dart';
import 'point_form_screen.dart';

class PointsScreen extends StatefulWidget {
  const PointsScreen({super.key});

  @override
  State<PointsScreen> createState() => _PointsScreenState();
}

class _PointsScreenState extends State<PointsScreen> {
  String? _filter; // categoria selecionada (null = todas)

  Future<void> _export(String kind, List<FieldPoint> pts) async {
    final app = context.read<AppState>();
    if (pts.isEmpty && kind != 'zip') {
      _snack('Nenhum ponto para exportar.');
      return;
    }
    try {
      final stamp = ExportService.stamp();
      File file;
      switch (kind) {
        case 'kml':
          file = await ExportService.writeText('pontos_$stamp.kml', ExportService.pointsToKml(pts));
        case 'geojson':
          file = await ExportService.writeText(
              'pontos_$stamp.geojson', ExportService.pointsToGeoJson(pts));
        case 'csv':
          file = await ExportService.writeText('pontos_$stamp.csv', ExportService.pointsToCsv(pts));
        default:
          _snack('Montando pacote com fotos e trilhas...');
          final tracks = <Track, List<TrackPoint>>{};
          for (final t in app.tracks) {
            tracks[t] = await app.trackPoints(t);
          }
          file = await ExportService.buildPackage(
              points: pts, tracks: tracks, photosDir: app.photosDir);
      }
      await ExportService.share([file], text: 'Dados de campo - VerdeMap');
    } catch (e) {
      _snack('Erro ao exportar: $e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pts = _filter == null ? app.points : app.points.where((p) => p.category == _filter).toList();
    final gps = app.myLatLng;

    return Scaffold(
      appBar: AppBar(
        title: Text('Pontos (${pts.length})'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.ios_share),
            tooltip: 'Exportar',
            onSelected: (k) => _export(k, pts),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'kml', child: Text('KML (Google Earth)')),
              PopupMenuItem(value: 'geojson', child: Text('GeoJSON (QGIS)')),
              PopupMenuItem(value: 'csv', child: Text('CSV (planilha)')),
              PopupMenuItem(value: 'zip', child: Text('Pacote completo .zip (com fotos e trilhas)')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 56,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: const Text('Todas'),
                    selected: _filter == null,
                    onSelected: (_) => setState(() => _filter = null),
                  ),
                ),
                for (final c in FieldPoint.categories)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(c),
                      selected: _filter == c,
                      onSelected: (_) => setState(() => _filter = c),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: pts.isEmpty
                ? const Center(child: Text('Nenhum ponto registrado.'))
                : ListView.separated(
                    itemCount: pts.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final fp = pts[i];
                      final dist = gps == null
                          ? ''
                          : ' · ${GeoUtils.formatDistance(GeoUtils.distance(gps, fp.latLng))}';
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: CategoryStyle.color(fp.category),
                          child: Icon(CategoryStyle.icon(fp.category), color: Colors.white),
                        ),
                        title: Text(fp.title),
                        subtitle: Text('${ExportService.formatDateTime(fp.createdAt)}$dist\n'
                            '${GeoUtils.format(fp.latLng, app.coordFormat)}'),
                        isThreeLine: true,
                        trailing: fp.photos.isEmpty
                            ? null
                            : Row(mainAxisSize: MainAxisSize.min, children: [
                                const Icon(Icons.photo, size: 18),
                                Text('${fp.photos.length}'),
                              ]),
                        onTap: () => _showActions(fp),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _showActions(FieldPoint fp) {
    final app = context.read<AppState>();
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(fp.title), subtitle: Text(fp.category)),
          ListTile(
            leading: const Icon(Icons.map),
            title: const Text('Ver no mapa'),
            onTap: () {
              Navigator.pop(ctx);
              Navigator.pop(context, fp.latLng);
            },
          ),
          ListTile(
            leading: const Icon(Icons.navigation),
            title: const Text('Navegar até o ponto'),
            onTap: () {
              app.setNavTarget(fp.latLng, fp.title);
              Navigator.pop(ctx);
              Navigator.pop(context, fp.latLng);
            },
          ),
          ListTile(
            leading: const Icon(Icons.edit),
            title: const Text('Editar / ver fotos'),
            onTap: () {
              Navigator.pop(ctx);
              Navigator.push(
                  context, MaterialPageRoute(builder: (_) => PointFormScreen(existing: fp)));
            },
          ),
        ]),
      ),
    );
  }
}
