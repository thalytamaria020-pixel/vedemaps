// Tela principal: mapa com GPS, pontos, trilhas, camadas e navegação.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../models/field_point.dart';
import '../models/vector_layer.dart';
import '../services/export_service.dart';
import '../services/map_sources.dart';
import '../state/app_state.dart';
import '../utils/geo_utils.dart';
import '../widgets/category_style.dart';
import '../widgets/geopdf_layer.dart';
import '../widgets/goto_dialog.dart';
import '../theme.dart';
import 'layers_screen.dart';
import 'navigation_screen.dart';
import 'offline_maps_screen.dart';
import 'point_form_screen.dart';
import 'points_screen.dart';
import 'tracks_screen.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _map = MapController();
  final ValueNotifier<LatLng> _center = ValueNotifier(const LatLng(-15.7939, -47.8828));
  late final AppState _app;
  bool _mapReady = false;
  bool _follow = true; // o mapa acompanha a posição do GPS
  LatLng? _lastGps;

  // Cache das camadas importadas (só é refeito quando elas mudam).
  int _cacheVersion = -1;
  List<Polygon> _polygons = [];
  List<Polyline> _layerLines = [];
  List<Marker> _layerMarkers = [];

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _app.addListener(_onAppChanged);
  }

  @override
  void dispose() {
    _app.removeListener(_onAppChanged);
    _center.dispose();
    super.dispose();
  }

  void _onAppChanged() {
    final gps = _app.myLatLng;
    if (gps == null || !_mapReady) return;
    if (_follow && gps != _lastGps) {
      _map.move(gps, _lastGps == null ? 16 : _map.camera.zoom);
    }
    _lastGps = gps;
  }

  // ------------------------------------------------------------- Camadas

  void _rebuildLayerCache(AppState app) {
    if (_cacheVersion == app.layersVersion) return;
    _cacheVersion = app.layersVersion;
    final polygons = <Polygon>[];
    final lines = <Polyline>[];
    final markers = <Marker>[];
    for (final layer in app.layers.where((l) => l.visible)) {
      final color = Color(layer.colorValue);
      for (final f in layer.features) {
        switch (f.kind) {
          case GeomKind.polygon:
            for (final pg in f.polygons) {
              polygons.add(Polygon(
                points: pg.outer,
                holePointsList: pg.holes.isEmpty ? null : pg.holes,
                color: color.withValues(alpha: 0.18),
                borderColor: color,
                borderStrokeWidth: 2,
              ));
            }
          case GeomKind.line:
            for (final l in f.lines) {
              lines.add(Polyline(points: l, color: color, strokeWidth: 3));
            }
          case GeomKind.point:
            for (final pt in f.points) {
              markers.add(Marker(
                point: pt,
                width: 18,
                height: 18,
                child: GestureDetector(
                  onTap: () => _showFeatures([LayerHit(layer, f)]),
                  child: Container(
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
              ));
            }
        }
      }
    }
    _polygons = polygons;
    _layerLines = lines;
    _layerMarkers = markers;
  }

  // --------------------------------------------------------------- Build

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    _rebuildLayerCache(app);

    return Scaffold(
      appBar: AppBar(
        title: const Text('VerdeMap'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Ir para coordenada',
            onPressed: _goToCoordinate,
          ),
          IconButton(
            icon: const Icon(Icons.layers),
            tooltip: 'Mapa de fundo',
            onPressed: _chooseBaseMap,
          ),
        ],
      ),
      drawer: _buildDrawer(app),
      body: !app.ready
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                _buildMap(app),
                if (!_follow)
                  const IgnorePointer(
                    child: Center(child: Icon(Icons.add, size: 36, color: Colors.black87)),
                  ),
                Positioned(top: 8, left: 8, right: 8, child: _buildInfoPanel(app)),
              ],
            ),
      floatingActionButton: app.ready ? _buildButtons(app) : null,
    );
  }

  Widget _buildMap(AppState app) {
    final gps = app.myLatLng;
    final pos = app.position;
    final offline = app.offlineMap;

    final trackLines = <Polyline>[
      for (final path in app.visibleTracks.values)
        Polyline(points: path, color: Colors.deepOrange, strokeWidth: 4),
      if (app.recordingPath.length > 1)
        Polyline(points: List.of(app.recordingPath), color: Colors.red, strokeWidth: 5),
      if (gps != null && app.navTarget != null)
        Polyline(points: [gps, app.navTarget!], color: AppColors.primary, strokeWidth: 3),
    ];

    final pointMarkers = <Marker>[
      for (final fp in app.points)
        Marker(
          point: fp.latLng,
          width: 40,
          height: 40,
          alignment: Alignment.topCenter,
          child: GestureDetector(
            onTap: () => _showPointSheet(fp),
            child: Icon(Icons.location_on, size: 40, color: CategoryStyle.color(fp.category)),
          ),
        ),
      if (app.navTarget != null)
        Marker(
          point: app.navTarget!,
          width: 40,
          height: 40,
          alignment: Alignment.topCenter,
          child: const Icon(Icons.flag, size: 36, color: AppColors.primary),
        ),
      if (gps != null)
        Marker(
          point: gps,
          width: 34,
          height: 34,
          child: _GpsDot(heading: (pos != null && pos.speed > 1) ? pos.heading : null),
        ),
    ];

    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: _center.value,
        initialZoom: 4,
        minZoom: 2,
        maxZoom: 21,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
        onMapReady: () {
          _mapReady = true;
          _onAppChanged();
        },
        onPositionChanged: (camera, hasGesture) {
          _center.value = camera.center;
          if (hasGesture && _follow) setState(() => _follow = false);
        },
        onLongPress: (_, latLng) => _showLocationSheet(latLng),
        onTap: (_, latLng) => _identify(latLng),
      ),
      children: [
        if (app.baseMap.url != null)
          TileLayer(
            urlTemplate: app.baseMap.url,
            userAgentPackageName: 'br.app.verdemap',
            maxNativeZoom: 19,
          ),
        if (offline != null)
          TileLayer(
            key: ValueKey(offline.path),
            tileProvider: offline.tileProvider,
            minNativeZoom: offline.info.minZoom,
            maxNativeZoom: offline.info.maxZoom,
          ),
        if (app.pdfMaps.any((m) => m.visible)) GeoPdfLayer(maps: app.pdfMaps),
        if (_polygons.isNotEmpty) PolygonLayer(polygons: _polygons),
        if (_layerLines.isNotEmpty) PolylineLayer(polylines: _layerLines),
        if (trackLines.isNotEmpty) PolylineLayer(polylines: trackLines),
        if (gps != null && pos != null)
          CircleLayer(circles: [
            CircleMarker(
              point: gps,
              radius: pos.accuracy,
              useRadiusInMeter: true,
              color: AppColors.primary.withValues(alpha: 0.12),
              borderColor: AppColors.primary.withValues(alpha: 0.4),
              borderStrokeWidth: 1,
            ),
          ]),
        if (_layerMarkers.isNotEmpty) MarkerLayer(markers: _layerMarkers),
        MarkerLayer(markers: pointMarkers),
        if (app.baseMap.attribution.isNotEmpty)
          RichAttributionWidget(
            alignment: AttributionAlignment.bottomLeft,
            attributions: [TextSourceAttribution(app.baseMap.attribution)],
          ),
      ],
    );
  }

  Widget _buildInfoPanel(AppState app) {
    final theme = Theme.of(context);
    final pos = app.position;
    final gps = app.myLatLng;
    final rec = app.recording;

    String gpsText;
    if (app.locationError != null) {
      gpsText = app.locationError!;
    } else if (gps == null) {
      gpsText = 'Aguardando sinal do GPS...';
    } else {
      gpsText = GeoUtils.format(gps, app.coordFormat);
    }

    return Column(
      children: [
        Card(
          child: InkWell(
            onTap: _chooseCoordFormat,
            onLongPress: app.locationError != null ? app.startLocation : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(
                      gps == null ? Icons.gps_off : Icons.gps_fixed,
                      size: 18,
                      color: gps == null ? theme.colorScheme.error : AppColors.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(gpsText,
                          style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()], fontSize: 13)),
                    ),
                    ActionChip(
                      label: Text(_shortFormat(app.coordFormat)),
                      avatar: const Icon(Icons.expand_more, size: 16),
                      tooltip: 'Trocar formato da coordenada',
                      visualDensity: VisualDensity.compact,
                      onPressed: _chooseCoordFormat,
                    ),
                    const SizedBox(width: 6),
                    if (pos != null)
                      Text('±${pos.accuracy.toStringAsFixed(0)} m',
                          style: TextStyle(
                            fontSize: 12,
                            color: pos.accuracy > 20 ? AppColors.warning : AppColors.primary,
                          )),
                  ]),
                  if (!_follow)
                    ValueListenableBuilder<LatLng>(
                      valueListenable: _center,
                      builder: (_, c, __) => Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(children: [
                          const Icon(Icons.add, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(GeoUtils.format(c, app.coordFormat),
                                style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()], fontSize: 13)),
                          ),
                          if (gps != null)
                            Text(GeoUtils.formatDistance(GeoUtils.distance(gps, c)),
                                style: const TextStyle(fontSize: 12)),
                        ]),
                      ),
                    ),
                  if (rec != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(children: [
                        const Icon(Icons.fiber_manual_record, size: 14, color: Colors.red),
                        const SizedBox(width: 8),
                        Text('Gravando: ${GeoUtils.formatDistance(rec.distanceMeters)} · '
                            '${_fmtDuration(rec.duration)}'),
                      ]),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (app.navTarget != null) _buildNavPanel(app),
      ],
    );
  }

  Widget _buildNavPanel(AppState app) {
    final gps = app.myLatLng;
    final target = app.navTarget!;
    final info = gps == null
        ? 'Aguardando GPS'
        : '${GeoUtils.formatDistance(GeoUtils.distance(gps, target))} · rumo '
            '${GeoUtils.bearing(gps, target).toStringAsFixed(0)}° '
            '(${GeoUtils.cardinal(GeoUtils.bearing(gps, target))})';
    return Card(
      color: AppColors.primarySoft,
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.flag, color: AppColors.primary),
        title: Text(app.navTargetName ?? 'Destino'),
        subtitle: Text(info),
        onTap: () => Navigator.push(
            context, MaterialPageRoute(builder: (_) => const NavigationScreen())),
        trailing: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Encerrar navegação',
          onPressed: app.clearNavTarget,
        ),
      ),
    );
  }

  Widget _buildButtons(AppState app) {
    final recording = app.recording != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        FloatingActionButton.small(
          heroTag: 'rec',
          tooltip: recording ? 'Parar gravação' : 'Gravar trilha',
          backgroundColor: recording ? Colors.red : null,
          foregroundColor: recording ? Colors.white : null,
          onPressed: _toggleRecording,
          child: Icon(recording ? Icons.stop : Icons.route),
        ),
        const SizedBox(height: 12),
        FloatingActionButton.small(
          heroTag: 'me',
          tooltip: 'Centralizar na minha posição',
          onPressed: _centerOnMe,
          child: Icon(_follow ? Icons.gps_fixed : Icons.gps_not_fixed),
        ),
        const SizedBox(height: 12),
        FloatingActionButton.extended(
          heroTag: 'add',
          onPressed: _addPointHere,
          icon: const Icon(Icons.add_location_alt),
          label: Text(_follow ? 'Ponto no GPS' : 'Ponto na mira'),
        ),
      ],
    );
  }

  Drawer _buildDrawer(AppState app) {
    return Drawer(
      child: ListView(
        children: [
          DrawerHeader(
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const Icon(Icons.travel_explore, size: 40),
                const SizedBox(height: 8),
                Text('VerdeMap', style: Theme.of(context).textTheme.titleLarge),
                Text('${app.points.length} pontos · ${app.tracks.length} trilhas · '
                    '${app.layers.length} camadas'),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.place),
            title: const Text('Pontos registrados'),
            onTap: () => _open(const PointsScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.route),
            title: const Text('Trilhas'),
            onTap: () => _open(const TracksScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.layers_outlined),
            title: const Text('Camadas (KML, SHP, GeoJSON)'),
            onTap: () => _open(const LayersScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.download_for_offline),
            title: const Text('Mapas offline e PDF'),
            subtitle: Text([
              app.offlineMap?.info.name ?? 'Nenhum .mbtiles ativo',
              if (app.pdfMaps.isNotEmpty)
                '${app.pdfMaps.where((m) => m.visible).length} de ${app.pdfMaps.length} PDF visíveis',
            ].join(' · ')),
            onTap: () => _open(OfflineMapsScreen(
                visibleBounds: _mapReady ? _map.camera.visibleBounds : null)),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.explore),
            title: const Text('Bússola / navegação'),
            onTap: () => _open(const NavigationScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.pin_drop),
            title: const Text('Formato de coordenadas'),
            subtitle: Text(app.coordFormat.label),
            onTap: () {
              Navigator.pop(context);
              _chooseCoordFormat();
            },
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Sobre'),
            onTap: () {
              Navigator.pop(context);
              showAboutDialog(
                context: context,
                applicationName: 'VerdeMap',
                applicationVersion: '1.0.0',
                children: const [
                  Text('Mapeamento e navegação GPS offline para apoio à '
                      'fiscalização ambiental em campo.\n\n'
                      'Datum das coordenadas: WGS84 / SIRGAS 2000.'),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------- Ações

  Future<void> _open(Widget screen) async {
    Navigator.pop(context); // fecha o menu lateral
    final result = await Navigator.push<Object?>(
        context, MaterialPageRoute(builder: (_) => screen));
    if (!mounted || result == null) return;
    setState(() => _follow = false);
    if (result is LatLng) {
      _map.move(result, math.max(_map.camera.zoom, 16));
    } else if (result is LatLngBounds) {
      _map.fitCamera(CameraFit.bounds(bounds: result, padding: const EdgeInsets.all(48)));
    }
  }

  void _centerOnMe() {
    final gps = _app.myLatLng;
    if (gps == null) {
      _snack(_app.locationError ?? 'Aguardando sinal do GPS...');
      if (_app.locationError != null) _app.startLocation();
      return;
    }
    setState(() => _follow = true);
    _map.move(gps, math.max(_map.camera.zoom, 16));
  }

  void _addPointHere() {
    if (_follow) {
      final pos = _app.position;
      if (pos == null) {
        _snack('Sem sinal de GPS. Arraste o mapa e use a mira, ou toque e segure no mapa.');
        return;
      }
      _openPointForm(LatLng(pos.latitude, pos.longitude), pos.altitude, pos.accuracy);
    } else {
      _openPointForm(_center.value, null, null);
    }
  }

  void _openPointForm(LatLng location, double? altitude, double? accuracy) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PointFormScreen(location: location, altitude: altitude, accuracy: accuracy),
      ),
    );
  }

  Future<void> _toggleRecording() async {
    if (_app.recording == null) {
      if (_app.locationError != null) await _app.startLocation();
      if (_app.locationError != null) {
        _snack(_app.locationError!);
        return;
      }
      await _app.startRecording();
      _snack('Gravação de trilha iniciada. Ela continua com a tela desligada.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Parar gravação?'),
        content: const Text('A trilha será salva e poderá ser exportada em GPX ou KML.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Continuar gravando')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Parar e salvar')),
        ],
      ),
    );
    if (ok == true) {
      await _app.stopRecording();
      _snack('Trilha salva.');
    }
  }

  Future<void> _goToCoordinate() async {
    final ll = await showDialog<LatLng>(
      context: context,
      builder: (_) => GoToCoordinateDialog(
        initialFormat: _app.coordFormat,
        initial: _app.myLatLng ?? (_follow ? null : _center.value),
      ),
    );
    if (ll == null || !mounted) return;
    setState(() => _follow = false);
    _map.move(ll, math.max(_map.camera.zoom, 15));
    _showLocationSheet(ll);
  }

  Future<void> _chooseBaseMap() async {
    final chosen = await showDialog<BaseMap>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Mapa de fundo (online)'),
        children: [
          for (final b in BaseMap.values)
            ListTile(
              leading: Icon(b == _app.baseMap ? Icons.check_circle : Icons.circle_outlined),
              title: Text(b.label),
              onTap: () => Navigator.pop(ctx, b),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Text('Sem internet, o mapa de fundo não carrega. Use um mapa offline '
                '(menu > Mapas offline), que é desenhado por cima.'),
          ),
        ],
      ),
    );
    if (chosen != null) await _app.setBaseMap(chosen);
  }

  static String _shortFormat(CoordFormat f) => switch (f) {
        CoordFormat.decimal => 'Decimal',
        CoordFormat.dms => 'GMS',
        CoordFormat.utm => 'UTM',
      };

  /// Folha para escolher o formato, mostrando a posição atual em cada um.
  Future<void> _chooseCoordFormat() async {
    final ref = _app.myLatLng ?? _center.value;
    final chosen = await showModalBottomSheet<CoordFormat>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Formato da coordenada', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 4),
              const Text('Vale para o mapa, os pontos e a tela de navegação.'),
              const SizedBox(height: 12),
              for (final f in CoordFormat.values)
                Card(
                  elevation: 0,
                  color: f == _app.coordFormat
                      ? Theme.of(ctx).colorScheme.primaryContainer
                      : Theme.of(ctx).colorScheme.surfaceContainerHighest,
                  child: ListTile(
                    leading: Icon(f == _app.coordFormat ? Icons.radio_button_checked : Icons.radio_button_off),
                    title: Text(f.label),
                    subtitle: Text(GeoUtils.format(ref, f),
                        style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
                    onTap: () => Navigator.pop(ctx, f),
                  ),
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.search),
                label: const Text('Digitar uma coordenada'),
                onPressed: () {
                  Navigator.pop(ctx);
                  _goToCoordinate();
                },
              ),
            ],
          ),
        ),
      ),
    );
    if (chosen != null) await _app.setCoordFormat(chosen);
  }

  // ---------------------------------------------------- Painéis inferiores

  void _showLocationSheet(LatLng ll) {
    final hits = _app.layersAt(ll);
    final gps = _app.myLatLng;
    final allFormats = CoordFormat.values.map((f) => GeoUtils.format(ll, f)).join('\n');
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.my_location),
                title: SelectableText(allFormats),
                subtitle: gps == null
                    ? null
                    : Text('A ${GeoUtils.formatDistance(GeoUtils.distance(gps, ll))} de você, '
                        'rumo ${GeoUtils.bearing(gps, ll).toStringAsFixed(0)}°'),
              ),
              if (hits.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.warning_amber, color: AppColors.warning),
                  title: const Text('Este local está dentro de:'),
                  subtitle: Text(hits.map((h) => '${h.layer.name}: ${h.feature.label}').join('\n')),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showFeatures(hits);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.add_location_alt),
                title: const Text('Registrar ponto aqui'),
                onTap: () {
                  Navigator.pop(ctx);
                  _openPointForm(ll, null, null);
                },
              ),
              ListTile(
                leading: const Icon(Icons.navigation),
                title: const Text('Navegar até aqui'),
                onTap: () {
                  Navigator.pop(ctx);
                  _app.setNavTarget(ll, 'Local marcado');
                },
              ),
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('Copiar coordenadas'),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: allFormats));
                  Navigator.pop(ctx);
                  _snack('Coordenadas copiadas.');
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _identify(LatLng ll) {
    final hits = _app.layersAt(ll);
    if (hits.isNotEmpty) _showFeatures(hits);
  }

  void _showFeatures(List<LayerHit> hits) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        maxChildSize: 0.9,
        builder: (_, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            for (final h in hits) ...[
              Text(h.layer.name, style: Theme.of(ctx).textTheme.labelLarge),
              Text(h.feature.label, style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 4),
              for (final e in h.feature.properties.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text.rich(TextSpan(children: [
                    TextSpan(text: '${e.key}: ', style: const TextStyle(fontWeight: FontWeight.bold)),
                    TextSpan(text: '${e.value ?? ''}'),
                  ])),
                ),
              const Divider(height: 24),
            ],
          ],
        ),
      ),
    );
  }

  void _showPointSheet(FieldPoint fp) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(CategoryStyle.icon(fp.category), color: CategoryStyle.color(fp.category)),
                const SizedBox(width: 8),
                Expanded(child: Text(fp.title, style: Theme.of(ctx).textTheme.titleMedium)),
              ]),
              const SizedBox(height: 4),
              Text('${fp.category} · ${ExportService.formatDateTime(fp.createdAt)}'),
              SelectableText(GeoUtils.format(fp.latLng, _app.coordFormat),
                  style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
              if (fp.notes.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(fp.notes),
              ],
              if (fp.photos.isNotEmpty) ...[
                const SizedBox(height: 8),
                SizedBox(
                  height: 90,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final ph in fp.photos)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(File(_app.photoPath(ph)),
                                width: 90, height: 90, fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => const Icon(Icons.broken_image)),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Wrap(spacing: 8, children: [
                FilledButton.icon(
                  icon: const Icon(Icons.navigation),
                  label: const Text('Navegar'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _app.setNavTarget(fp.latLng, fp.title);
                  },
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.edit),
                  label: const Text('Editar'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    Navigator.push(context,
                        MaterialPageRoute(builder: (_) => PointFormScreen(existing: fp)));
                  },
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  static String _fmtDuration(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  }
}

/// Indicador da posição do usuário (ponto azul, com seta quando em movimento).
class _GpsDot extends StatelessWidget {
  const _GpsDot({this.heading});

  final double? heading;

  @override
  Widget build(BuildContext context) {
    if (heading == null) {
      return Container(
        margin: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: AppColors.primary,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
        ),
      );
    }
    return Transform.rotate(
      angle: heading! * math.pi / 180,
      child: const Icon(Icons.navigation, color: AppColors.primary, size: 34),
    );
  }
}
