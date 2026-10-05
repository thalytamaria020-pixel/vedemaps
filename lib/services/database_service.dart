// Banco de dados local (SQLite). Tudo fica no aparelho e funciona sem internet.

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/field_point.dart';
import '../models/track.dart';
import '../models/vector_layer.dart';

class DatabaseService {
  DatabaseService._();
  static final DatabaseService instance = DatabaseService._();

  Database? _db;

  Future<Database> get database async => _db ??= await _open();

  Future<Database> _open() async {
    final path = p.join(await getDatabasesPath(), 'verdemap.db');
    return openDatabase(
      path,
      version: 1,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE points (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            altitude REAL,
            accuracy REAL,
            created_at TEXT NOT NULL,
            category TEXT NOT NULL,
            title TEXT NOT NULL,
            notes TEXT,
            photos TEXT
          )''');
        await db.execute('''
          CREATE TABLE tracks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            started_at TEXT NOT NULL,
            ended_at TEXT,
            distance_m REAL DEFAULT 0
          )''');
        await db.execute('''
          CREATE TABLE track_points (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            altitude REAL,
            accuracy REAL,
            speed REAL,
            time TEXT NOT NULL
          )''');
        await db.execute('CREATE INDEX idx_track_points ON track_points(track_id)');
        await db.execute('''
          CREATE TABLE layers (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            color INTEGER NOT NULL,
            visible INTEGER NOT NULL DEFAULT 1,
            file_name TEXT NOT NULL,
            feature_count INTEGER,
            created_at TEXT NOT NULL
          )''');
        await db.execute('CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT)');
      },
    );
  }

  // ------------------------------------------------------------- Pontos

  Future<List<FieldPoint>> getPoints() async {
    final rows = await (await database).query('points', orderBy: 'created_at DESC');
    return rows.map(FieldPoint.fromMap).toList();
  }

  Future<int> insertPoint(FieldPoint point) async {
    return (await database).insert('points', point.toMap()..remove('id'));
  }

  Future<void> updatePoint(FieldPoint point) async {
    await (await database)
        .update('points', point.toMap(), where: 'id = ?', whereArgs: [point.id]);
  }

  Future<void> deletePoint(int id) async {
    await (await database).delete('points', where: 'id = ?', whereArgs: [id]);
  }

  // ------------------------------------------------------------ Trilhas

  Future<List<Track>> getTracks() async {
    final rows = await (await database).rawQuery('''
      SELECT t.*, (SELECT COUNT(*) FROM track_points tp WHERE tp.track_id = t.id) AS point_count
      FROM tracks t ORDER BY t.started_at DESC''');
    return rows.map(Track.fromMap).toList();
  }

  Future<int> insertTrack(Track track) async {
    return (await database).insert('tracks', track.toMap()..remove('id'));
  }

  Future<void> updateTrack(Track track) async {
    await (await database)
        .update('tracks', track.toMap(), where: 'id = ?', whereArgs: [track.id]);
  }

  Future<void> deleteTrack(int id) async {
    await (await database).delete('tracks', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> addTrackPoint(int trackId, TrackPoint tp) async {
    await (await database).insert('track_points', tp.toMap(trackId));
  }

  Future<List<TrackPoint>> getTrackPoints(int trackId) async {
    final rows = await (await database).query('track_points',
        where: 'track_id = ?', whereArgs: [trackId], orderBy: 'id');
    return rows.map(TrackPoint.fromMap).toList();
  }

  // ------------------------------------------------------------ Camadas

  Future<List<VectorLayer>> getLayers() async {
    final rows = await (await database).query('layers', orderBy: 'id');
    return rows.map(VectorLayer.fromMap).toList();
  }

  Future<int> insertLayer(VectorLayer layer) async {
    return (await database).insert('layers', layer.toMap()..remove('id'));
  }

  Future<void> updateLayer(VectorLayer layer) async {
    await (await database)
        .update('layers', layer.toMap(), where: 'id = ?', whereArgs: [layer.id]);
  }

  Future<void> deleteLayer(int id) async {
    await (await database).delete('layers', where: 'id = ?', whereArgs: [id]);
  }

  // ------------------------------------------------------ Configurações

  Future<String?> getSetting(String key) async {
    final rows = await (await database)
        .query('settings', where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setSetting(String key, String? value) async {
    await (await database).insert('settings', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
