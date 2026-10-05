/// Mapas de fundo online. Com internet, são exibidos normalmente; sem
/// internet, o app usa o mapa offline (.mbtiles) ativo, desenhado por cima.
enum BaseMap {
  none('Nenhum (somente mapa offline)', null, ''),
  osm('OpenStreetMap', 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      '© colaboradores do OpenStreetMap'),
  satellite(
      'Satélite (Esri World Imagery)',
      'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
      'Imagens © Esri, Maxar, Earthstar Geographics'),
  topo('Topográfico (OpenTopoMap)', 'https://tile.opentopomap.org/{z}/{x}/{y}.png',
      '© OpenTopoMap (CC-BY-SA)');

  const BaseMap(this.label, this.url, this.attribution);

  final String label;
  final String? url;
  final String attribution;
}

/// Fontes sugeridas para baixar áreas offline dentro do app.
/// IMPORTANTE: cada serviço tem termos de uso próprios. O servidor de tiles
/// do OpenStreetMap proíbe download em massa, por isso ele não aparece aqui.
/// O caminho recomendado para imagens de satélite é gerar o .mbtiles no QGIS
/// a partir de imagens que o órgão tem direito de usar (ver documentação).
class DownloadSource {
  const DownloadSource(this.label, this.urlTemplate, this.note);

  final String label;
  final String urlTemplate;
  final String note;

  static const presets = [
    DownloadSource(
      'Satélite (Esri World Imagery)',
      'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
      'Verifique os termos de uso da Esri: o uso offline em volume pode exigir licença.',
    ),
    DownloadSource(
      'URL personalizada (servidor do órgão, GeoServer, etc.)',
      '',
      'Use um servidor XYZ que você tenha autorização para baixar. '
          'Variáveis aceitas: {z}, {x}, {y} e {s}.',
    ),
  ];
}
