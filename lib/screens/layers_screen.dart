// Camadas vetoriais importadas (áreas embargadas, UCs, TIs, imóveis do CAR...).

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../models/vector_layer.dart';
import '../services/import_service.dart';
import '../state/app_state.dart';
import '../utils/pick_file.dart';

class LayersScreen extends StatefulWidget {
  const LayersScreen({super.key});

  @override
  State<LayersScreen> createState() => _LayersScreenState();
}

class _LayersScreenState extends State<LayersScreen> {
  bool _importing = false;

  Future<void> _import() async {
    final app = context.read<AppState>();
    final path = await pickLocalFile();
    if (path == null) return;

    final ext = p.extension(path).toLowerCase();
    if (!ImportService.supportedExtensions.contains(ext)) {
      _message('Formato não suportado',
          'Selecione um arquivo KML, KMZ, GeoJSON ou um Shapefile compactado em .zip '
          '(com os arquivos .shp, .dbf, .prj e .cpg).');
      return;
    }

    setState(() => _importing = true);
    try {
      final result = await app.importLayer(path);
      if (!mounted) return;
      final text = StringBuffer('${result.features.length} feições importadas de "${result.name}".');
      if (result.warnings.isNotEmpty) {
        text
          ..writeln()
          ..writeln()
          ..writeAll(result.warnings.map((w) => '• $w'), '\n');
      }
      _message('Camada importada', text.toString());
    } catch (e) {
      _message('Não foi possível importar', e.toString());
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _message(String title, String body) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(body)),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  Future<void> _pickColor(AppState app, VectorLayer layer) async {
    final color = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Cor da camada'),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final c in AppState.layerPalette)
                  InkWell(
                    onTap: () => Navigator.pop(ctx, c),
                    child: CircleAvatar(backgroundColor: Color(c), radius: 20),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (color != null) await app.updateLayer(layer.copyWith(colorValue: color));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Camadas')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _importing ? null : _import,
        icon: _importing
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.file_open),
        label: Text(_importing ? 'Importando...' : 'Importar arquivo'),
      ),
      body: app.layers.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Nenhuma camada importada.\n\n'
                  'Importe KML, KMZ, GeoJSON ou Shapefile (.zip) com áreas de interesse: '
                  'embargos, unidades de conservação, terras indígenas, imóveis do CAR, '
                  'polígonos de alertas de desmatamento etc.\n\n'
                  'Toque em um polígono no mapa para ver seus atributos.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: app.layers.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final layer = app.layers[i];
                return ListTile(
                  leading: GestureDetector(
                    onTap: () => _pickColor(app, layer),
                    child: CircleAvatar(backgroundColor: Color(layer.colorValue), radius: 14),
                  ),
                  title: Text(layer.name),
                  subtitle: Text('${layer.featureCount} feições'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch(
                        value: layer.visible,
                        onChanged: (v) => app.updateLayer(layer.copyWith(visible: v)),
                      ),
                      PopupMenuButton<String>(
                        onSelected: (a) async {
                          if (a == 'zoom') {
                            final b = layer.bbox;
                            if (b != null) {
                              Navigator.pop(
                                context,
                                LatLngBounds.fromPoints([
                                  LatLng(b.minLat, b.minLon),
                                  LatLng(b.maxLat, b.maxLon),
                                ]),
                              );
                            }
                          } else if (a == 'delete') {
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('Remover camada?'),
                                content: Text('"${layer.name}" será removida do aparelho.'),
                                actions: [
                                  TextButton(
                                      onPressed: () => Navigator.pop(ctx, false),
                                      child: const Text('Cancelar')),
                                  FilledButton(
                                      onPressed: () => Navigator.pop(ctx, true),
                                      child: const Text('Remover')),
                                ],
                              ),
                            );
                            if (ok == true) await app.deleteLayer(layer);
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'zoom', child: Text('Ver no mapa')),
                          PopupMenuItem(value: 'delete', child: Text('Remover')),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
