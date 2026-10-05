import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/map_screen.dart';
import 'state/app_state.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState()..init(),
      child: const VerdeMapApp(),
    ),
  );
}

class VerdeMapApp extends StatelessWidget {
  const VerdeMapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VerdeMap',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const MapScreen(),
    );
  }
}
