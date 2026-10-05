// Estado central do aplicativo. As telas "escutam" este objeto (padrão
// Provider/ChangeNotifier) e são redesenhadas quando algo muda.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/field_point.dart';
import '../models/track.dart';
import '../models/vector_layer.dart';
import '../services/database_service.dart';
import '../services/formats/geojson.dart';
import '../services/geopdf_service.dart';
import '../services/import_service.dart';
import '../services/location_service.dart';
import '../services/map_sources.dart';
import '../services/mbtiles_service.dart';
import '../utils/geo_utils.dart';

/// Resultado de "o que há neste local?" nas camadas importadas.
class LayerHit {
  LayerHit(this.layer, this.feature);
  final VectorLayer layer;
  final VectorFeature feature;
}

class AppState extends ChangeNotifier {
  final DatabaseService _db = DatabaseService.instance;

  bool ready = false;
  String? locationError;

  // Pastas do app
  String photosDir = '';
  String layersDir = '';
  String mapsDir = '';
  String pdfMapsDir = '';

  // GPS e bússola
  Position? position;
  double? compassHeading;
  StreamSubscription<Position>? _posSub;
  StreamSubscription<CompassEvent>? _compassSub;

  LatLng? get myLatLng =>
      position == null ? null : LatLng(position!.latitude, position!.longitude);

  // Dados
  List<FieldPoint> points = [];
  List<Track> tracks = [];
  List<VectorLayer> layers = [];
  int layersVersion = 0; // muda sempre que as camadas mudam (cache do mapa)
  final Map<int, List<LatLng>> visibleTracks = {};

  // Trilha em gravação
  Track? recording;
  final List<LatLng> recordingPath = [];
  LatLng? _lastRecorded;

  /// Leituras com precisão pior que este valor (m) não entram na trilha.
  static const double maxTrackAccuracy = 50;

  // Navegação até um alvo
  LatLng? navTarget;
  String? navTargetName;

  // Preferências
  CoordFormat coordFormat = CoordFormat.decimal;
  BaseMap baseMap = BaseMap.osm;
  MbTilesSource? offlineMap;

  /// Mapas em PDF georreferenciado (estilo Avenza).
  List<GeoPdfMap> pdfMaps = [];

  // ------------------------------------------------------ Inicialização

  Future<void> init() async {
    final docs = await getApplicationDocumentsDirectory();
    photosDir = p.join(docs.path, 'fotos');
    layersDir = p.join(docs.path, 'camadas');
    mapsDir = p.join(docs.path, 'mapas');
    pdfMapsDir = p.join(docs.path, 'mapas_pdf');
    for (final d in [photosDir, layersDir, mapsDir, pdfMapsDir]) {
      await Directory(d).create(recursive: true);
    }

    final fmt = await _db.getSetting('coord_format');
    coordFormat = CoordFormat.values.firstWhere((f) => f.name == fmt,
        orElse: () => CoordFormat.decimal);
    final base = await _db.getSetting('base_map');
    baseMap = BaseMap.values.firstWhere((b) => b.name == base, orElse: () => BaseMap.osm);

    points = await _db.getPoints();
    tracks = await _db.getTracks();
    await _loadLayers();
    pdfMaps = await GeoPdfMap.loadAll(pdfMapsDir);

    final active = await _db.getSetting('offline_map');
    if (active != null && File(p.join(mapsDir, active)).existsSync()) {
      try {
        offlineMap = await MbTilesSource.open(p.join(mapsDir, active));
      } catch (e) {
        debugPrint('Falha ao abrir mapa offline: $e');
      }
    }

    // Trilha que ficou aberta (ex.: app fechado pelo sistema): finaliza.
    for (final t in tracks.where((x) => x.endedAt == null)) {
      await _db.updateTrack(t.copyWith(endedAt: DateTime.now()));
    }
    tracks = await _db.getTracks();

    ready = true;
    notifyListeners();

    _compassSub = FlutterCompass.events?.listen((e) {
      compassHeading = e.heading;
      // não notifica aqui: a tela de navegação escuta a bússola diretamente
    });
    await startLocation();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _compassSub?.cancel();
    offlineMap?.close();
    super.dispose();
  }

  // ---------------------------------------------------------------- GPS

  Future<void> startLocation() async {
    locationError = await LocationService.ensurePermission();
    if (locationError != null) {
      notifyListeners();
      return;
    }
    _listen(recording: recording != null);
  }

  void _listen({required bool recording}) {
    _posSub?.cancel();
    _posSub = LocationService.positionStream(recording: recording).listen(
      _onPosition,
      onError: (Object e) {
        locationError = 'Erro no GPS: $e';
        notifyListeners();
      },
    );
  }

  void _onPosition(Position pos) {
    position = pos;
    locationError = null;
    if (recording != null) _recordPosition(pos);
    notifyListeners();
  }

  // ------------------------------------------------------------ Trilhas

  Future<void> startRecording() async {
    final now = DateTime.now();
    final track = Track(name: 'Trilha ${_fmt(now)}', startedAt: now);
    final id = await _db.insertTrack(track);
    recording = track.copyWith(id: id);
    recordingPath.clear();
    _lastRecorded = null;
    _listen(recording: true);
    notifyListeners();
  }

  Future<void> _recordPosition(Position pos) async {
    final rec = recording;
    if (rec == null || pos.accuracy > maxTrackAccuracy) return;
    final ll = LatLng(pos.latitude, pos.longitude);
    var dist = rec.distanceMeters;
    if (_lastRecorded != null) {
      final d = GeoUtils.distance(_lastRecorded!, ll);
      if (d < 2) return; // parado: evita acumular ruído do GPS
      dist += d;
    }
    _lastRecorded = ll;
    recordingPath.add(ll);
    recording = rec.copyWith(distanceMeters: dist, pointCount: recordingPath.length);
    await _db.addTrackPoint(
      rec.id!,
      TrackPoint(
        latitude: pos.latitude,
        longitude: pos.longitude,
        altitude: pos.altitude,
        accuracy: pos.accuracy,
        speed: pos.speed,
        time: pos.timestamp,
      ),
    );
  }

  Future<void> stopRecording() async {
    final rec = recording;
    if (rec == null) return;
    await _db.updateTrack(rec.copyWith(endedAt: DateTime.now()));
    visibleTracks[rec.id!] = List.of(recordingPath);
    recording = null;
    recordingPath.clear();
    tracks = await _db.getTracks();
    _listen(recording: false);
    notifyListeners();
  }

  Future<void> toggleTrackVisible(Track t) async {
    if (visibleTracks.containsKey(t.id)) {
      visibleTracks.remove(t.id);
    } else {
      visibleTracks[t.id!] = (await _db.getTrackPoints(t.id!)).map((e) => e.latLng).toList();
    }
    notifyListeners();
  }

  Future<List<TrackPoint>> trackPoints(Track t) => _db.getTrackPoints(t.id!);

  Future<void> renameTrack(Track t, String name) async {
    await _db.updateTrack(t.copyWith(name: name));
    tracks = await _db.getTracks();
    notifyListeners();
  }

  Future<void> deleteTrack(Track t) async {
    await _db.deleteTrack(t.id!);
    visibleTracks.remove(t.id);
    tracks = await _db.getTracks();
    notifyListeners();
  }

  // ------------------------------------------------------------- Pontos

  String photoPath(String name) => p.join(photosDir, name);

  /// Copia uma foto (da câmera ou galeria) para a pasta do app.
  Future<String> savePhoto(String sourcePath) async {
    final ext = p.extension(sourcePath).isEmpty ? '.jpg' : p.extension(sourcePath);
    final name = 'foto_${DateTime.now().millisecondsSinceEpoch}$ext';
    await File(sourcePath).copy(photoPath(name));
    return name;
  }

  Future<void> deletePhotoFile(String name) async {
    final f = File(photoPath(name));
    if (await f.exists()) await f.delete();
  }

  Future<void> savePoint(FieldPoint point) async {
    if (point.id == null) {
      await _db.insertPoint(point);
    } else {
      await _db.updatePoint(point);
    }
    points = await _db.getPoints();
    notifyListeners();
  }

  Future<void> deletePoint(FieldPoint point) async {
    for (final ph in point.photos) {
      await deletePhotoFile(ph);
    }
    await _db.deletePoint(point.id!);
    points = await _db.getPoints();
    notifyListeners();
  }

  // ---------------------------------------------------------- Navegação

  void setNavTarget(LatLng target, [String? name]) {
    navTarget = target;
    navTargetName = name;
    notifyListeners();
  }

  void clearNavTarget() {
    navTarget = null;
    navTargetName = null;
    notifyListeners();
  }

  // ------------------------------------------------------------ Camadas

  static const layerPalette = [
    0xFFE53935, 0xFFFFB300, 0xFF8E24AA, 0xFF1E88E5,
    0xFF00ACC1, 0xFF43A047, 0xFFF4511E, 0xFF6D4C41,
  ];

  Future<void> _loadLayers() async {
    layers = await _db.getLayers();
    for (final l in layers) {
      final f = File(p.join(layersDir, l.fileName));
      if (!await f.exists()) continue;
      final text = await f.readAsString();
      l.features = await compute(GeoJson.parse, text);
    }
    layersVersion++;
  }

  Future<ImportResult> importLayer(String path) async {
    final result = await ImportService.importFile(path);
    if (result.features.isEmpty) {
      throw ImportException('Nenhuma feição válida foi encontrada no arquivo.');
    }
    final fileName = 'camada_${DateTime.now().millisecondsSinceEpoch}.geojson';
    final features = result.features;
    final json = await compute(GeoJson.encode, features);
    await File(p.join(layersDir, fileName)).writeAsString(json);
    final layer = VectorLayer(
      name: result.name,
      colorValue: layerPalette[layers.length % layerPalette.length],
      fileName: fileName,
      featureCount: features.length,
      createdAt: DateTime.now(),
      features: features,
    );
    final id = await _db.insertLayer(layer);
    layers.add(layer.copyWith(id: id));
    layersVersion++;
    notifyListeners();
    return result;
  }

  Future<void> updateLayer(VectorLayer layer) async {
    await _db.updateLayer(layer);
    final i = layers.indexWhere((l) => l.id == layer.id);
    if (i >= 0) layers[i] = layer;
    layersVersion++;
    notifyListeners();
  }

  Future<void> deleteLayer(VectorLayer layer) async {
    await _db.deleteLayer(layer.id!);
    final f = File(p.join(layersDir, layer.fileName));
    if (await f.exists()) await f.delete();
    layers.removeWhere((l) => l.id == layer.id);
    layersVersion++;
    notifyListeners();
  }

  /// Polígonos das camadas visíveis que contêm o ponto (ex.: "este ponto
  /// está dentro da área embargada X / da UC Y").
  List<LayerHit> layersAt(LatLng point) => [
        for (final l in layers.where((l) => l.visible))
          for (final f in l.features)
            if (f.kind == GeomKind.polygon && f.containsPoint(point)) LayerHit(l, f),
      ];

  // ------------------------------------------------------ Mapas offline

  List<File> offlineMapFiles() {
    final dir = Directory(mapsDir);
    if (!dir.existsSync()) return [];
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.mbtiles'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }

  Future<void> setOfflineMap(String? path) async {
    await offlineMap?.close();
    offlineMap = null;
    if (path != null) offlineMap = await MbTilesSource.open(path);
    await _db.setSetting('offline_map', path == null ? null : p.basename(path));
    notifyListeners();
  }

  Future<String> importOfflineMap(String sourcePath) async {
    final dest = p.join(mapsDir, p.basename(sourcePath));
    await File(sourcePath).copy(dest);
    return dest;
  }

  Future<void> deleteOfflineMap(File f) async {
    if (offlineMap?.path == f.path) await setOfflineMap(null);
    await f.delete();
    notifyListeners();
  }

  // ------------------------------------------------------- Mapas em PDF

  Future<GeoPdfMap> importPdfMap(String path, {void Function(double)? onProgress}) async {
    final map = await GeoPdfService.importPdf(
      path,
      pdfMapsDir,
      name: p.basenameWithoutExtension(path),
      onProgress: onProgress,
    );
    pdfMaps.add(map);
    notifyListeners();
    return map;
  }

  Future<void> updatePdfMap(GeoPdfMap map) async {
    await map.save();
    notifyListeners();
  }

  Future<void> deletePdfMap(GeoPdfMap map) async {
    final d = Directory(map.dir);
    if (await d.exists()) await d.delete(recursive: true);
    pdfMaps.remove(map);
    notifyListeners();
  }

  // ------------------------------------------------------- Preferências

  Future<void> setCoordFormat(CoordFormat f) async {
    coordFormat = f;
    await _db.setSetting('coord_format', f.name);
    notifyListeners();
  }

  void cycleCoordFormat() =>
      setCoordFormat(CoordFormat.values[(coordFormat.index + 1) % CoordFormat.values.length]);

  Future<void> setBaseMap(BaseMap b) async {
    baseMap = b;
    await _db.setSetting('base_map', b.name);
    notifyListeners();
  }

  static String _fmt(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.day)}/${two(t.month)} ${two(t.hour)}:${two(t.minute)}';
  }
}
