// Formulário para registrar (ou editar) um ponto de fiscalização.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../models/field_point.dart';
import '../services/export_service.dart';
import '../state/app_state.dart';
import '../utils/geo_utils.dart';
import '../widgets/category_style.dart';
import '../theme.dart';

class PointFormScreen extends StatefulWidget {
  const PointFormScreen({
    super.key,
    this.existing,
    this.location,
    this.altitude,
    this.accuracy,
  }) : assert(existing != null || location != null);

  final FieldPoint? existing;
  final LatLng? location;
  final double? altitude;
  final double? accuracy;

  @override
  State<PointFormScreen> createState() => _PointFormScreenState();
}

class _PointFormScreenState extends State<PointFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _notes = TextEditingController();
  final _picker = ImagePicker();
  late String _category;
  late List<String> _photos;
  final List<String> _newPhotos = []; // fotos tiradas nesta edição
  final List<String> _removedPhotos = [];
  bool _saved = false;
  bool _busy = false;
  late final AppState _app;

  LatLng get _location => widget.existing?.latLng ?? widget.location!;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    final e = widget.existing;
    _category = e?.category ?? FieldPoint.categories.first;
    _title.text = e?.title ?? '';
    _notes.text = e?.notes ?? '';
    _photos = List.of(e?.photos ?? const []);
  }

  @override
  void dispose() {
    // Saiu sem salvar: apaga as fotos novas para não ocupar espaço.
    if (!_saved) {
      for (final ph in _newPhotos) {
        _app.deletePhotoFile(ph);
      }
    }
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _addPhoto(ImageSource source) async {
    try {
      final file = await _picker.pickImage(source: source, imageQuality: 80, maxWidth: 2560);
      if (file == null) return;
      final name = await _app.savePhoto(file.path);
      setState(() {
        _photos.add(name);
        _newPhotos.add(name);
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Não foi possível obter a foto: $e')));
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    final now = DateTime.now();
    final title = _title.text.trim().isEmpty
        ? '$_category ${ExportService.formatDateTime(now)}'
        : _title.text.trim();
    final e = widget.existing;
    final point = e == null
        ? FieldPoint(
            latitude: _location.latitude,
            longitude: _location.longitude,
            altitude: widget.altitude,
            accuracy: widget.accuracy,
            createdAt: now,
            category: _category,
            title: title,
            notes: _notes.text.trim(),
            photos: _photos,
          )
        : e.copyWith(category: _category, title: title, notes: _notes.text.trim(), photos: _photos);
    await _app.savePoint(point);
    for (final ph in _removedPhotos) {
      await _app.deletePhotoFile(ph);
    }
    _saved = true;
    if (mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Excluir ponto?'),
        content: const Text('O ponto e suas fotos serão apagados deste aparelho.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Excluir')),
        ],
      ),
    );
    if (ok != true) return;
    await _app.deletePoint(widget.existing!);
    _saved = true;
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final hits = app.layersAt(_location);
    final editing = widget.existing != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'Editar ponto' : 'Novo ponto'),
        actions: [
          if (editing)
            IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Excluir', onPressed: _delete),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final f in CoordFormat.values)
                      SelectableText(GeoUtils.format(_location, f),
                          style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
                    if (widget.accuracy != null || widget.existing?.accuracy != null)
                      Text('Precisão do GPS: ±'
                          '${(widget.accuracy ?? widget.existing!.accuracy!).toStringAsFixed(0)} m'),
                    if (widget.accuracy == null && widget.existing == null)
                      const Text('Ponto marcado no mapa (não é a posição do GPS).',
                          style: TextStyle(fontStyle: FontStyle.italic)),
                  ],
                ),
              ),
            ),
            if (hits.isNotEmpty)
              Card(
                color: AppColors.warningSoft,
                child: ListTile(
                  leading: const Icon(Icons.warning_amber, color: AppColors.warning),
                  title: const Text('Dentro de:'),
                  subtitle: Text(hits.map((h) => '${h.layer.name}: ${h.feature.label}').join('\n')),
                ),
              ),
            const SizedBox(height: 16),
            Text('Categoria', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in FieldPoint.categories)
                  ChoiceChip(
                    avatar: Icon(CategoryStyle.icon(c), size: 18, color: CategoryStyle.color(c)),
                    label: Text(c),
                    selected: c == _category,
                    onSelected: (_) => setState(() => _category = c),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _title,
              decoration: const InputDecoration(
                labelText: 'Título',
                hintText: 'Ex.: Área desmatada recente',
                border: OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _notes,
              decoration: const InputDecoration(
                labelText: 'Observações',
                hintText: 'Descrição, nº do auto, responsável, área estimada...',
                border: OutlineInputBorder(),
              ),
              minLines: 3,
              maxLines: 8,
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 16),
            Row(children: [
              Text('Fotos (${_photos.length})', style: Theme.of(context).textTheme.labelLarge),
              const Spacer(),
              IconButton.filledTonal(
                icon: const Icon(Icons.photo_camera),
                tooltip: 'Tirar foto',
                onPressed: () => _addPhoto(ImageSource.camera),
              ),
              IconButton.filledTonal(
                icon: const Icon(Icons.photo_library),
                tooltip: 'Escolher da galeria',
                onPressed: () => _addPhoto(ImageSource.gallery),
              ),
            ]),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final ph in _photos)
                  Stack(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(File(app.photoPath(ph)),
                          width: 100, height: 100, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              const SizedBox(width: 100, height: 100, child: Icon(Icons.broken_image))),
                    ),
                    Positioned(
                      top: 0,
                      right: 0,
                      child: IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        style: IconButton.styleFrom(backgroundColor: Colors.black54),
                        onPressed: () => setState(() {
                          _photos.remove(ph);
                          _removedPhotos.add(ph);
                        }),
                      ),
                    ),
                  ]),
              ],
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _busy ? null : _save,
              icon: const Icon(Icons.save),
              label: const Text('Salvar ponto'),
            ),
          ],
        ),
      ),
    );
  }
}
