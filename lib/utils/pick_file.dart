// Abre o seletor de arquivos do sistema e devolve o caminho de um arquivo
// local que o app consegue ler (ou null se o usuário cancelar).

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<String?> pickLocalFile() async {
  final file = await FilePicker.pickFile();
  if (file == null) return null;

  final path = file.path;
  if (path != null && await File(path).exists()) return path;

  // Alguns aparelhos entregam só o conteúdo (sem caminho): grava uma cópia.
  final dir = await getTemporaryDirectory();
  final copy = File(p.join(dir.path, file.name));
  await copy.writeAsBytes(await file.readAsBytes());
  return copy.path;
}
