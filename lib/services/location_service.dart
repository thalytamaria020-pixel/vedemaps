// Acesso ao GPS do aparelho (pacote geolocator).
// O GPS funciona sem internet: ele recebe sinal diretamente dos satélites.

import 'dart:io' show Platform;

import 'package:geolocator/geolocator.dart';

class LocationService {
  LocationService._();

  /// Verifica se o GPS está ligado e se o app tem permissão.
  /// Retorna null se estiver tudo certo, ou uma mensagem de erro.
  static Future<String?> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return 'A localização do aparelho está desligada. Ative o GPS.';
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied) {
      return 'Permissão de localização negada.';
    }
    if (perm == LocationPermission.deniedForever) {
      return 'Permissão de localização bloqueada. Libere nas configurações do aparelho.';
    }
    return null;
  }

  /// Fluxo contínuo de posições.
  /// Com [recording] = true, o Android mostra uma notificação fixa e o GPS
  /// continua ativo com a tela desligada (necessário para gravar trilhas).
  static Stream<Position> positionStream({required bool recording}) {
    final LocationSettings settings;
    if (Platform.isAndroid) {
      settings = AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: recording ? 3 : 1,
        intervalDuration: const Duration(seconds: 2),
        foregroundNotificationConfig: recording
            ? const ForegroundNotificationConfig(
                notificationTitle: 'VerdeMap',
                notificationText: 'Gravando trilha. Toque para abrir o app.',
                enableWakeLock: true,
              )
            : null,
      );
    } else if (Platform.isIOS) {
      settings = AppleSettings(
        accuracy: LocationAccuracy.best,
        activityType: ActivityType.otherNavigation,
        distanceFilter: recording ? 3 : 1,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: recording,
        allowBackgroundLocationUpdates: recording,
      );
    } else {
      settings = const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 1);
    }
    return Geolocator.getPositionStream(locationSettings: settings);
  }
}
