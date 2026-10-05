// Mapas offline: PDF georreferenciado (estilo Avenza) e .mbtiles
// (importar, ativar, baixar e excluir).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../services/geopdf_service.dart';
import '../services/map_sources.dart';
import '../services/tile_downloader.dart';
import '../state/app_state.dart';
import '../utils/pick_file.dart';

String _size(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

class OfflineMapsScreen extends StatefulWidget {
  const OfflineMapsScreen({super.key, this.visibleBounds});

  /// Área visível no mapa quando a tela foi aberta (usada no download).
  final LatLngBounds? visibleBounds;

  @override
  State<OfflineMapsScreen> createState() => _OfflineMapsScreenState();
}

class _OfflineMapsScreenState extends State<OfflineMapsScreen> {
  bool _busy = false;

  Future<void> _import(AppState app) async {
    final path = await pickLocalFile();
    if (path == null) return;
    if (!path.toLowerCase().endsWith('.mbtiles')) {
      _snack('Selecione um arquivo .mbtiles');
      return;
    }
    setState(() => _busy = true);
    try {
      final dest = await app.importOfflineMap(path);
      await app.setOfflineMap(dest);
      _snack('Mapa importado e ativado.');
    } catch (e) {
      _snack('Erro ao importar: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );

  Future<void> _importPdf(AppState app) async {
    final path = await pickLocalFile();
    if (path == null || !mounted) return;
    if (!path.toLowerCase().endsWith('.pdf')) {
      _snack('Selecione um arquivo .pdf');
      return;
    }

    final progress = ValueNotifier<double>(0);
    final navigator = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Preparando mapa PDF'),
          content: ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (_, v, __) => Column(mainAxisSize: MainAxisSize.min, children: [
              LinearProgressIndicator(value: v == 0 ? null : v),
              const SizedBox(height: 12),
              Text(v == 0
                  ? 'Lendo o georreferenciamento...'
                  : '${(v * 100).round()}% · desenhando o mapa em alta resolução'),
            ]),
          ),
        ),
      ),
    );

    setState(() => _busy = true);
    try {
      final map = await app.importPdfMap(path, onProgress: (v) => progress.value = v);
      navigator.pop();
      if (!mounted) return;
      if (map.warnings.isNotEmpty) {
        await _showInfo(map);
        if (!mounted) return;
      }
      Navigator.pop(context, map.bounds);
    } catch (e) {
      navigator.pop();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Não foi possível usar este PDF'),
          content: Text('$e'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
    } finally {
      progress.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showInfo(GeoPdfMap m) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(m.name),
          content: Text(m.warnings.isEmpty
              ? 'Georreferenciamento lido sem avisos.'
              : m.warnings.map((w) => '• $w').join('\n\n')),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );

  Future<void> _pdfAction(AppState app, GeoPdfMap m, String action) async {
    switch (action) {
      case 'zoom':
        if (!m.visible) {
          m.visible = true;
          await app.updatePdfMap(m);
        }
        if (mounted) Navigator.pop(context, m.bounds);
      case 'opacity':
        var value = m.opacity;
        await showDialog<void>(
          context: context,
          builder: (ctx) => StatefulBuilder(
            builder: (ctx, setLocal) => AlertDialog(
              title: const Text('Transparência do mapa'),
              content: Slider(
                value: value,
                min: 0.2,
                max: 1,
                divisions: 8,
                label: '${(value * 100).round()}%',
                onChanged: (v) => setLocal(() => value = v),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
              ],
            ),
          ),
        );
        m.opacity = value;
        await app.updatePdfMap(m);
      case 'info':
        await _showInfo(m);
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Excluir mapa PDF?'),
            content: Text('"${m.name}" será removido do aparelho (o PDF original não é afetado).'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Excluir')),
            ],
          ),
        );
        if (ok == true) await app.deletePdfMap(m);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final files = app.offlineMapFiles();
    final activePath = app.offlineMap?.path;

    return Scaffold(
      appBar: AppBar(title: const Text('Mapas offline e PDF')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (_busy) const LinearProgressIndicator(),
          _sectionTitle('Mapas em PDF georreferenciado'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.icon(
              onPressed: _busy ? null : () => _importPdf(app),
              icon: const Icon(Icons.picture_as_pdf),
              label: const Text('Importar PDF georreferenciado'),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Mesmo tipo de mapa usado no Avenza Maps (PDF geoespacial exportado pelo QGIS, '
              'ArcGIS, IBGE etc.). A preparação leva de 1 a 5 minutos e só é feita uma vez.',
              style: TextStyle(fontSize: 12),
            ),
          ),
          for (final m in app.pdfMaps)
            ListTile(
              leading: Icon(Icons.picture_as_pdf,
                  color: m.visible ? Theme.of(context).colorScheme.primary : Colors.grey),
              title: Text(m.name),
              subtitle: Text(m.warnings.isEmpty
                  ? (m.visible ? 'Visível no mapa' : 'Oculto')
                  : '⚠ ${m.warnings.first}'),
              onTap: () => Navigator.pop(context, m.bounds),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Switch(
                  value: m.visible,
                  onChanged: (v) {
                    m.visible = v;
                    app.updatePdfMap(m);
                  },
                ),
                PopupMenuButton<String>(
                  onSelected: (a) => _pdfAction(app, m, a),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'zoom', child: Text('Ver no mapa')),
                    PopupMenuItem(value: 'opacity', child: Text('Transparência')),
                    PopupMenuItem(value: 'info', child: Text('Avisos e detalhes')),
                    PopupMenuItem(value: 'delete', child: Text('Excluir')),
                  ],
                ),
              ]),
            ),
          const Divider(height: 32),
          _sectionTitle('Mapas em blocos (.mbtiles)'),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: widget.visibleBounds == null
                      ? null
                      : () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => DownloadAreaScreen(bounds: widget.visibleBounds!),
                            ),
                          ),
                  icon: const Icon(Icons.download),
                  label: const Text('Baixar área visível'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _import(app),
                  icon: const Icon(Icons.file_open),
                  label: const Text('Importar .mbtiles'),
                ),
              ),
            ]),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Dica: imagens de satélite de alta resolução podem ser preparadas no QGIS '
              '(Processamento › "Gerar tiles XYZ (MBTiles)") e copiadas para o celular.',
              style: TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(height: 8),
          ListTile(
            leading: Icon(activePath == null ? Icons.check_circle : Icons.circle_outlined),
            title: const Text('Nenhum mapa offline'),
            onTap: () => app.setOfflineMap(null),
          ),
          for (final f in files)
            ListTile(
              leading: Icon(
                f.path == activePath ? Icons.check_circle : Icons.circle_outlined,
                color: f.path == activePath ? Theme.of(context).colorScheme.primary : null,
              ),
              title: Text(p.basenameWithoutExtension(f.path)),
              subtitle: Text(_size(f.lengthSync()) +
                  (f.path == activePath
                      ? ' · zoom ${app.offlineMap!.info.minZoom}–${app.offlineMap!.info.maxZoom}'
                      : '')),
              onTap: () async {
                try {
                  await app.setOfflineMap(f.path);
                  final b = app.offlineMap?.info.bounds;
                  if (b != null && context.mounted) Navigator.pop(context, b);
                } catch (e) {
                  _snack('Não foi possível abrir o mapa: $e');
                }
              },
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _confirmDelete(app, f),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(AppState app, File f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Excluir mapa offline?'),
        content: Text('${p.basename(f.path)} (${_size(f.lengthSync())}) será apagado.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Excluir')),
        ],
      ),
    );
    if (ok == true) await app.deleteOfflineMap(f);
  }
}

// ---------------------------------------------------------------------------

class DownloadAreaScreen extends StatefulWidget {
  const DownloadAreaScreen({super.key, required this.bounds});

  final LatLngBounds bounds;

  @override
  State<DownloadAreaScreen> createState() => _DownloadAreaScreenState();
}

class _DownloadAreaScreenState extends State<DownloadAreaScreen> {
  final _name = TextEditingController(text: 'area_${DateTime.now().millisecondsSinceEpoch ~/ 1000}');
  final _url = TextEditingController(text: DownloadSource.presets.first.urlTemplate);
  DownloadSource _source = DownloadSource.presets.first;
  RangeValues _zoom = const RangeValues(10, 16);
  bool _authorized = false;
  CancelToken? _cancel;
  DownloadProgress? _progress;
  String? _error;

  int get _tiles =>
      TileDownloader.countTiles(widget.bounds, _zoom.start.round(), _zoom.end.round());

  @override
  void dispose() {
    _cancel?.cancel();
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final app = context.read<AppState>();
    final name = _name.text.trim().replaceAll(RegExp(r'[^\w\-]+'), '_');
    final url = _url.text.trim();
    if (name.isEmpty || !url.contains('{z}') || !url.contains('{x}') || !url.contains('{y}')) {
      setState(() => _error = 'Informe um nome e uma URL com {z}, {x} e {y}.');
      return;
    }
    final path = p.join(app.mapsDir, '$name.mbtiles');
    final cancel = CancelToken();
    setState(() {
      _cancel = cancel;
      _error = null;
      _progress = DownloadProgress(done: 0, total: _tiles, failed: 0, bytes: 0);
    });

    await for (final prog in TileDownloader.download(
      urlTemplate: url,
      bounds: widget.bounds,
      minZoom: _zoom.start.round(),
      maxZoom: _zoom.end.round(),
      outputPath: path,
      name: name,
      cancel: cancel,
    ).handleError((Object e) {
      if (mounted) setState(() => _error = 'Erro: $e');
    })) {
      if (!mounted) return;
      setState(() => _progress = prog);
      if (prog.finished) {
        setState(() => _cancel = null);
        if (prog.done - prog.failed > 0) {
          await app.setOfflineMap(path);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('${prog.cancelled ? "Download interrompido" : "Download concluído"}: '
                  '${prog.done - prog.failed} tiles (${_size(prog.bytes)}). Mapa ativado.'),
            ));
          }
        }
        if (prog.failed > 0 && mounted) {
          setState(() => _error = '${prog.failed} tiles falharam (sem internet ou bloqueados '
              'pelo servidor). Você pode repetir o download com o mesmo nome para completar.');
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tiles = _tiles;
    final tooMany = tiles > TileDownloader.maxTiles;
    final running = _cancel != null;
    final prog = _progress;

    return Scaffold(
      appBar: AppBar(title: const Text('Baixar área para uso offline')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Área: ${widget.bounds.south.toStringAsFixed(4)}, ${widget.bounds.west.toStringAsFixed(4)}  →  '
            '${widget.bounds.north.toStringAsFixed(4)}, ${widget.bounds.east.toStringAsFixed(4)}',
            style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()], fontSize: 12),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            enabled: !running,
            decoration: const InputDecoration(labelText: 'Nome do mapa', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          const Text('Fonte das imagens'),
          DropdownButton<DownloadSource>(
            isExpanded: true,
            value: _source,
            onChanged: running
                ? null
                : (s) => setState(() {
                      _source = s!;
                      _url.text = s.urlTemplate;
                    }),
            items: [
              for (final s in DownloadSource.presets)
                DropdownMenuItem(value: s, child: Text(s.label, overflow: TextOverflow.ellipsis)),
            ],
          ),
          Text(_source.note, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          TextField(
            controller: _url,
            enabled: !running,
            decoration: const InputDecoration(
              labelText: 'URL dos tiles (XYZ)',
              hintText: 'https://servidor/{z}/{x}/{y}.png',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Text('Níveis de zoom: ${_zoom.start.round()} a ${_zoom.end.round()}'),
          RangeSlider(
            values: _zoom,
            min: 1,
            max: 19,
            divisions: 18,
            labels: RangeLabels('${_zoom.start.round()}', '${_zoom.end.round()}'),
            onChanged: running ? null : (v) => setState(() => _zoom = v),
          ),
          const Text(
            'Referência: zoom 13 ≈ 19 m/pixel · zoom 16 ≈ 2,4 m/pixel · zoom 18 ≈ 0,6 m/pixel',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          Text(
            'Estimativa: $tiles tiles, cerca de ${_size(tiles * TileDownloader.avgTileBytes)}',
            style: TextStyle(fontWeight: FontWeight.bold, color: tooMany ? Colors.red : null),
          ),
          if (tooMany)
            Text(
              'Acima do limite de ${TileDownloader.maxTiles} tiles. Aproxime o mapa (área menor) '
              'ou reduza o zoom máximo.',
              style: const TextStyle(color: Colors.red),
            ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _authorized,
            onChanged: running ? null : (v) => setState(() => _authorized = v ?? false),
            title: const Text('Confirmo que o uso desta fonte para download offline é '
                'permitido pelos termos do serviço ou pelo órgão.'),
          ),
          const SizedBox(height: 8),
          if (prog != null) ...[
            LinearProgressIndicator(value: prog.fraction),
            const SizedBox(height: 4),
            Text('${prog.done}/${prog.total} tiles · ${_size(prog.bytes)}'
                '${prog.failed > 0 ? ' · ${prog.failed} falhas' : ''}'),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const SizedBox(height: 16),
          running
              ? OutlinedButton.icon(
                  onPressed: () => _cancel?.cancel(),
                  icon: const Icon(Icons.stop),
                  label: const Text('Interromper'),
                )
              : FilledButton.icon(
                  onPressed: (!_authorized || tooMany || tiles == 0) ? null : _start,
                  icon: const Icon(Icons.download),
                  label: const Text('Iniciar download'),
                ),
        ],
      ),
    );
  }
}
