# VerdeMap

Aplicativo de mapeamento e navegação GPS **offline** para apoio à fiscalização ambiental em campo.
Feito em Flutter (Android e iOS).

## O que o app faz

- Mapa com posição do GPS, precisão (±m) e coordenadas em **decimal, GMS ou UTM (SIRGAS 2000)**
- **Mapas em PDF georreferenciado**, como no Avenza Maps (PDF geoespacial do QGIS, ArcGIS, IBGE...)
- **Mapas offline** (.mbtiles): importados do QGIS ou baixados no próprio app
- **Pontos de ocorrência** com categoria, observações, **fotos**, data/hora e precisão
- **Trilhas**: gravação do percurso (inclusive com a tela desligada)
- **Navegação até um alvo** com distância, rumo e bússola (ideal para áreas sem estrada)
- **Importação** de KML, KMZ, GeoJSON e **Shapefile (.zip)**, com consulta de atributos e aviso
  "este ponto está dentro de: ..." (embargos, UCs, TIs, CAR etc.)
- **Exportação**: KML, GeoJSON, CSV, GPX e pacote .zip completo com fotos

## Estrutura do projeto

```
lib/
  main.dart                     ponto de entrada
  models/                       dados: ponto, trilha, camada
  services/                     banco de dados, GPS, mapas offline, importação, exportação
    formats/                    leitores de GeoJSON, KML e Shapefile
  state/app_state.dart          estado central (Provider)
  screens/                      telas
  utils/geo_utils.dart          UTM, GMS, distância, rumo
  widgets/                      componentes reutilizáveis
test/                           testes automatizados
plataforma/                     configurações de Android e iOS para copiar
```

## Caminho mais fácil: o GitHub gera o instalador para você

Não precisa instalar nada no computador.

1. Crie uma conta em https://github.com e um repositório **privado** chamado `verdemap`
   (botão **+** › **New repository**; não marque nenhuma opção extra).
2. Na página do repositório vazio, clique em **uploading an existing file**, arraste **todo o
   conteúdo** desta pasta (inclusive a pasta `.github`) e clique em **Commit changes**.
3. Abra a aba **Actions**. A tarefa **Gerar APK** roda sozinha (10 a 15 minutos).
4. Quando aparecer o ✓ verde, clique na execução e baixe **VerdeMap-apk** em *Artifacts*.
   Dentro do .zip está o `app-release.apk`.
5. Passe o `.apk` para o celular, toque nele e permita "instalar apps desconhecidos".

Para atualizar o app: envie os arquivos novos ao repositório (**Add file › Upload files**),
espere o novo APK e instale por cima. Os dados do celular são mantidos.

> A chave de assinatura em `plataforma/android/debug.keystore` serve para uso interno. Para
> distribuir oficialmente (Play Store ou MDM do órgão), gere uma chave própria e guarde-a em sigilo.

## Passo a passo para rodar (iniciante)

### 1. Instale as ferramentas (uma vez só)

1. **Flutter**: siga https://docs.flutter.dev/get-started/install (escolha seu sistema e "Android").
2. **Android Studio**: https://developer.android.com/studio — durante a instalação, aceite o
   Android SDK. Depois rode no terminal: `flutter doctor --android-licenses` e aceite tudo.
3. **VS Code** (opcional, recomendado) com a extensão "Flutter".
4. Rode `flutter doctor` e resolva o que aparecer com ✗ (as mensagens explicam o que fazer).

### 2. Prepare o projeto

Abra o terminal **dentro da pasta `verdemap`** e rode:

```bash
flutter create --platforms=android,ios --org br.gov.fiscalizacao .
flutter pub get
```

O primeiro comando cria as pastas `android/` e `ios/` sem apagar o código em `lib/`.

### 3. Configure as permissões

- **Android**: copie `plataforma/android/AndroidManifest.xml` para
  `android/app/src/main/AndroidManifest.xml` (substitua o arquivo existente).
- **iOS** (só com Mac): cole o conteúdo de `plataforma/ios/Info.plist-trecho.xml` dentro de
  `ios/Runner/Info.plist`, logo após a primeira linha `<dict>`.

### 4. Rode no celular

1. No celular Android: ative **Opções do desenvolvedor** (toque 7 vezes em "Número da versão")
   e ligue a **Depuração USB**.
2. Conecte o cabo e rode:

```bash
flutter run
```

### 5. Gere o instalador (APK)

```bash
flutter build apk --release
```

O arquivo fica em `build/app/outputs/flutter-apk/app-release.apk`. Pode ser copiado para outros
celulares (será preciso permitir "instalar apps de fontes desconhecidas").

### 6. Rode os testes

```bash
flutter test
```

## Mapas em PDF georreferenciado (como no Avenza)

1. Copie o PDF para o celular.
2. No app: **Menu › Mapas offline e PDF › Importar PDF georreferenciado**.
3. Aguarde a preparação (1 a 5 minutos, só na primeira vez). O mapa abre alinhado ao GPS.

Aceita o padrão "PDF geoespacial" (ISO 32000), que é o que QGIS, ArcGIS e GDAL exportam hoje,
em coordenadas geográficas ou UTM. Para gerar no QGIS: **Projeto › Importar/Exportar ›
Exportar mapa para PDF**, marcando **Incluir informações geoespaciais**.
O padrão antigo da TerraGo (GeoPDF/OGC) ainda não é lido: reexporte pelo QGIS.

## Mapas offline de satélite (recomendado: QGIS)

1. No QGIS, carregue a imagem (ex.: mosaico Planet/Sentinel/CBERS a que o seu setor tenha acesso,
   ou uma camada XYZ permitida).
2. Enquadre a área de interesse.
3. Menu **Processamento › Caixa de ferramentas › "Gerar tiles XYZ (MBTiles)"**.
4. Extensão: "usar extensão da tela"; zoom mínimo 8, máximo 16 ou 17; formato JPG (menor).
5. Copie o `.mbtiles` para o celular e no app: **Menu › Mapas offline › Importar .mbtiles**.

## Problemas comuns

| Sintoma | O que fazer |
|---|---|
| `flutter pub get` falha por versão | `flutter pub upgrade --major-versions` e rode de novo |
| Erro de "compileSdk" ou "namespace" no Android | Atualize o Flutter (`flutter upgrade`) e rode `flutter clean` |
| GPS "aguardando sinal" | Vá para céu aberto; a primeira posição pode levar 1 a 2 minutos |
| Mapa cinza sem internet | Ative um mapa offline em **Menu › Mapas offline** |
| PDF "sem georreferenciamento" | Reexporte no QGIS com "Incluir informações geoespaciais" |
| Shapefile não importa | Compacte `.shp`, `.dbf`, `.prj`, `.cpg` em um `.zip`; se a projeção não for UTM ou geográfica, reprojete no QGIS para EPSG:4674 |

## Licenças de dados

Os mapas online usam OpenStreetMap, Esri e OpenTopoMap, cada um com seus termos de uso.
O servidor de tiles do OpenStreetMap proíbe download em massa, por isso não é oferecido para uso offline.
