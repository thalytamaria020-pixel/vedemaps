import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import '../utils/geo_utils.dart';

/// Caixa "Ir para coordenada": o usuário escolhe o formato (decimal, GMS ou
/// UTM) e preenche campos separados. Retorna um LatLng ou null.
class GoToCoordinateDialog extends StatefulWidget {
  const GoToCoordinateDialog({super.key, this.initialFormat = CoordFormat.decimal, this.initial});

  final CoordFormat initialFormat;

  /// Posição usada para pré-preencher os campos (ex.: GPS atual).
  final LatLng? initial;

  @override
  State<GoToCoordinateDialog> createState() => _GoToCoordinateDialogState();
}

class _GoToCoordinateDialogState extends State<GoToCoordinateDialog> {
  late CoordFormat _format = widget.initialFormat;
  String? _error;

  // Decimal
  final _lat = TextEditingController();
  final _lon = TextEditingController();
  // GMS
  final _latD = TextEditingController(), _latM = TextEditingController(), _latS = TextEditingController();
  final _lonD = TextEditingController(), _lonM = TextEditingController(), _lonS = TextEditingController();
  bool _south = true;
  bool _west = true;
  // UTM
  final _zone = TextEditingController();
  final _east = TextEditingController();
  final _north = TextEditingController();
  bool _utmSouth = true;

  List<TextEditingController> get _all =>
      [_lat, _lon, _latD, _latM, _latS, _lonD, _lonM, _lonS, _zone, _east, _north];

  @override
  void initState() {
    super.initState();
    final p = widget.initial;
    if (p != null) _fillFrom(p);
  }

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  /// Preenche todos os formatos a partir de um ponto (ao abrir, ou ao trocar
  /// de aba com um ponto válido: a coordenada é convertida automaticamente).
  void _fillFrom(LatLng p) {
    String dec(double v) => v.toStringAsFixed(6).replaceAll('.', ',');
    _lat.text = dec(p.latitude);
    _lon.text = dec(p.longitude);

    void dms(double v, TextEditingController d, TextEditingController m, TextEditingController s) {
      final a = v.abs();
      var dd = a.floor();
      final mf = (a - dd) * 60;
      var mm = mf.floor();
      var ss = double.parse(((mf - mm) * 60).toStringAsFixed(2));
      if (ss >= 60) {
        ss -= 60;
        mm++;
      }
      if (mm >= 60) {
        mm -= 60;
        dd++;
      }
      d.text = '$dd';
      m.text = '$mm';
      s.text = ss.toStringAsFixed(2).replaceAll('.', ',');
    }

    dms(p.latitude, _latD, _latM, _latS);
    dms(p.longitude, _lonD, _lonM, _lonS);
    _south = p.latitude < 0;
    _west = p.longitude < 0;

    final u = GeoUtils.toUtm(p.latitude, p.longitude);
    _zone.text = '${u.zone}';
    _east.text = u.easting.toStringAsFixed(0);
    _north.text = u.northing.toStringAsFixed(0);
    _utmSouth = u.south;
  }

  double? _num(TextEditingController c) =>
      double.tryParse(c.text.trim().replaceAll(' ', '').replaceAll(',', '.'));

  /// Lê os campos do formato atual. Retorna null e preenche [_error] se algo
  /// estiver errado.
  LatLng? _read() {
    switch (_format) {
      case CoordFormat.decimal:
        final lat = _num(_lat), lon = _num(_lon);
        if (lat == null || lon == null) return _fail('Preencha latitude e longitude.');
        if (lat.abs() > 90) return _fail('Latitude deve estar entre -90 e 90.');
        if (lon.abs() > 180) return _fail('Longitude deve estar entre -180 e 180.');
        return LatLng(lat, lon);

      case CoordFormat.dms:
        final ld = _num(_latD), lm = _num(_latM) ?? 0, ls = _num(_latS) ?? 0;
        final od = _num(_lonD), om = _num(_lonM) ?? 0, os = _num(_lonS) ?? 0;
        if (ld == null || od == null) return _fail('Preencha pelo menos os graus.');
        if (lm >= 60 || om >= 60 || ls >= 60 || os >= 60 || lm < 0 || om < 0 || ls < 0 || os < 0) {
          return _fail('Minutos e segundos devem ficar entre 0 e 59.');
        }
        final lat = (ld.abs() + lm / 60 + ls / 3600) * (_south ? -1 : 1);
        final lon = (od.abs() + om / 60 + os / 3600) * (_west ? -1 : 1);
        if (lat.abs() > 90 || lon.abs() > 180) return _fail('Coordenada fora do globo.');
        return LatLng(lat, lon);

      case CoordFormat.utm:
        final z = int.tryParse(_zone.text.trim());
        final e = _num(_east), n = _num(_north);
        if (z == null || e == null || n == null) return _fail('Preencha zona, E e N.');
        if (z < 1 || z > 60) return _fail('Zona UTM deve estar entre 1 e 60 (no Brasil, 18 a 25).');
        if (e < 100000 || e > 900000) return _fail('E (leste) deve ter 6 dígitos, entre 100000 e 900000.');
        if (n < 0 || n > 10000000) return _fail('N (norte) deve ter até 7 dígitos.');
        return GeoUtils.fromUtm(z, _utmSouth, e, n);
    }
  }

  LatLng? _fail(String msg) {
    setState(() => _error = msg);
    return null;
  }

  void _changeFormat(CoordFormat f) {
    // Converte o que já foi digitado para o novo formato, se for válido.
    final current = _read();
    setState(() {
      if (current != null) _fillFrom(current);
      _format = f;
      _error = null;
    });
  }

  void _submit() {
    setState(() => _error = null);
    final p = _read();
    if (p != null) Navigator.pop(context, p);
  }

  // ---------------------------------------------------------------- UI

  static final _decimalInput = [FilteringTextInputFormatter.allow(RegExp(r'[0-9,.\-]'))];
  static final _intInput = [FilteringTextInputFormatter.digitsOnly];

  Widget _field(TextEditingController c, String label,
      {String? helper, bool decimal = true, bool signed = false, Key? key, double? width}) {
    final f = TextField(
      key: key,
      controller: c,
      textAlign: width != null ? TextAlign.center : TextAlign.start,
      keyboardType: TextInputType.numberWithOptions(decimal: decimal, signed: signed),
      inputFormatters: decimal ? _decimalInput : _intInput,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        border: const OutlineInputBorder(),
        isDense: width != null,
      ),
      onSubmitted: (_) => _submit(),
    );
    return width == null ? f : SizedBox(width: width, child: f);
  }

  Widget _toggle(String a, String b, bool firstSelected, ValueChanged<bool> onChanged) {
    return SegmentedButton<bool>(
      showSelectedIcon: false,
      segments: [
        ButtonSegment(value: true, label: Text(a)),
        ButtonSegment(value: false, label: Text(b)),
      ],
      selected: {firstSelected},
      onSelectionChanged: (s) => setState(() => onChanged(s.first)),
    );
  }

  Widget _dmsRow(String title, TextEditingController d, TextEditingController m,
      TextEditingController s, Widget hemisphere) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(child: _field(d, '°', decimal: false)),
          const SizedBox(width: 6),
          Expanded(child: _field(m, "'", decimal: false)),
          const SizedBox(width: 6),
          Expanded(flex: 2, child: _field(s, '"')),
        ]),
        const SizedBox(height: 8),
        hemisphere,
      ],
    );
  }

  Widget _body() {
    switch (_format) {
      case CoordFormat.decimal:
        return Column(children: [
          _field(_lat, 'Latitude', helper: 'Negativo = Sul (ex.: -15,7939)', signed: true, key: const Key('lat')),
          const SizedBox(height: 12),
          _field(_lon, 'Longitude', helper: 'Negativo = Oeste (ex.: -47,8828)', signed: true, key: const Key('lon')),
        ]);
      case CoordFormat.dms:
        return Column(children: [
          _dmsRow('Latitude', _latD, _latM, _latS,
              _toggle('Sul (S)', 'Norte (N)', _south, (v) => _south = v)),
          const SizedBox(height: 16),
          _dmsRow('Longitude', _lonD, _lonM, _lonS,
              _toggle('Oeste (W)', 'Leste (E)', _west, (v) => _west = v)),
        ]);
      case CoordFormat.utm:
        return Column(children: [
          Row(children: [
            SizedBox(width: 88, child: _field(_zone, 'Zona', decimal: false)),
            const SizedBox(width: 12),
            Expanded(child: _toggle('Sul', 'Norte', _utmSouth, (v) => _utmSouth = v)),
          ]),
          const SizedBox(height: 12),
          _field(_east, 'Leste (E)', helper: '6 dígitos, ex.: 191139', decimal: false),
          const SizedBox(height: 12),
          _field(_north, 'Norte (N)', helper: '7 dígitos, ex.: 8251746', decimal: false),
          const SizedBox(height: 4),
          Text('Datum SIRGAS 2000 / WGS84', style: Theme.of(context).textTheme.bodySmall),
        ]);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Ir para coordenada'),
      scrollable: true,
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<CoordFormat>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: CoordFormat.decimal, label: Text('Decimal')),
                ButtonSegment(value: CoordFormat.dms, label: Text('GMS')),
                ButtonSegment(value: CoordFormat.utm, label: Text('UTM')),
              ],
              selected: {_format},
              onSelectionChanged: (s) => _changeFormat(s.first),
            ),
            const SizedBox(height: 16),
            _body(),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: _submit, child: const Text('Ir')),
      ],
    );
  }
}
