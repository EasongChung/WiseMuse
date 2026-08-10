import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// [v0.1.0] 语音/大模型文件下载与解压管理。
///
/// Vosk 中文小模型 `vosk-model-small-cn-0.22`（~42MB）运行时下载，
/// 解压到 app 私有目录；已存在则跳过（可重复执行）。
class ModelStore {
  ModelStore._();

  /// Vosk 中文小模型（短句跟读够用）。
  static const String voskCnModelUrl =
      'https://alphacephei.com/vosk/models/vosk-model-small-cn-0.22.zip';
  static const String voskCnModelDir = 'vosk-model-small-cn-0.22';

  /// 模型根目录（`{documents}/models`）。
  static Future<Directory> modelsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'models'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 确保模型就绪，返回模型目录路径。
  ///
  /// 已存在直接返回；否则下载 zip → 解压 → 清理 zip。
  static Future<String> ensureVoskCnModel() async {
    final root = await modelsDir();
    final modelDir = Directory(p.join(root.path, voskCnModelDir));
    if (await modelDir.exists()) {
      return modelDir.path;
    }

    final zipPath = p.join(root.path, '$voskCnModelDir.zip');
    await _download(voskCnModelUrl, zipPath);
    await _extractZip(zipPath, root.path);
    await File(zipPath).delete();

    if (!await modelDir.exists()) {
      throw Exception('模型解压后目录缺失: $voskCnModelDir');
    }
    return modelDir.path;
  }

  static Future<void> _download(String url, String savePath) async {
    final resp = await http.get(Uri.parse(url));
    if (resp.statusCode != 200) {
      throw Exception('模型下载失败: HTTP ${resp.statusCode}');
    }
    await File(savePath).writeAsBytes(resp.bodyBytes, flush: true);
  }

  static Future<void> _extractZip(String zipPath, String destDir) async {
    final bytes = await File(zipPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final file in archive) {
      final outPath = p.join(destDir, file.name);
      if (file.isFile) {
        await File(outPath)
            .create(recursive: true)
            .then(
              (f) => f.writeAsBytes(
                List<int>.from(file.content as List<int>),
                flush: true,
              ),
            );
      }
    }
  }
}
