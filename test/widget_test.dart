// Testes de interface da caixa "Ir para coordenada".

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verdemap/utils/geo_utils.dart';
import 'package:verdemap/widgets/goto_dialog.dart';
import 'package:latlong2/latlong.dart';

Future<LatLng?> _open(WidgetTester tester, Widget dialog, Future<void> Function() fill) async {
  LatLng? result;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (ctx) => TextButton(
          onPressed: () async {
            result = await showDialog<LatLng>(context: ctx, builder: (_) => dialog);
          },
          child: const Text('abrir'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('abrir'));
  await tester.pumpAndSettle();
  await fill();
  await tester.tap(find.text('Ir'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('Campos vazios mostram erro', (tester) async {
    final r = await _open(tester, const GoToCoordinateDialog(), () async {});
    expect(r, isNull);
    expect(find.textContaining('Preencha'), findsOneWidget);
  });

  testWidgets('Decimal com vírgula', (tester) async {
    final r = await _open(tester, const GoToCoordinateDialog(), () async {
      await tester.enterText(find.byKey(const Key('lat')), '-15,7939');
      await tester.enterText(find.byKey(const Key('lon')), '-47,8828');
    });
    expect(r!.latitude, closeTo(-15.7939, 1e-9));
    expect(r.longitude, closeTo(-47.8828, 1e-9));
  });

  testWidgets('GMS pré-preenchido volta para o mesmo ponto', (tester) async {
    final r = await _open(
      tester,
      const GoToCoordinateDialog(
        initialFormat: CoordFormat.dms,
        initial: LatLng(-3.456667, -60.123333),
      ),
      () async {},
    );
    expect(r!.latitude, closeTo(-3.456667, 1e-4));
    expect(r.longitude, closeTo(-60.123333, 1e-4));
  });

  testWidgets('Trocar de Decimal para UTM converte o valor digitado', (tester) async {
    final r = await _open(tester, const GoToCoordinateDialog(), () async {
      await tester.enterText(find.byKey(const Key('lat')), '-15.7939');
      await tester.enterText(find.byKey(const Key('lon')), '-47.8828');
      await tester.tap(find.text('UTM'));
      await tester.pumpAndSettle();
      expect(find.text('191139'), findsOneWidget);
    });
    expect(GeoUtils.distance(r!, const LatLng(-15.7939, -47.8828)), lessThan(2));
  });
}
