import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/debug/app_log.dart';

/// [v0.1.0] 语音/大模型文件下载与解压管理。
///
/// Vosk 中文小模型 `vosk-model-small-cn-0.22`（~42MB）运行时下载或离线导入，
/// 解压到 app 私有目录；已存在则跳过（可重复执行）。
///
/// **解压必须流式**：整包读入 + `List<int>.from(content)` 会把 30MB 的
/// `Uint8List` 装箱成 4 字节/元素的 `List<int>`（约 120MB），叠加原始
/// zip 与解压缓冲后峰值超过 200MB，直接被系统 OOM kill（无 Dart 异常，
/// 表现为进程秒退）。此处统一走 `extractFileToDisk` 的
/// `InputFileStream → OutputFileStream` 流式管道，内存占用恒定。
class ModelStore {
  ModelStore._();

  static const String _tag = 'model_store';

  /// Vosk 中文小模型（短句跟读够用）。
  /// 主源为 GitHub 镜像（alphacephei.com 在国内网络常 DNS 解析失败），
  /// 失败时回退官方源。
  static const String voskCnModelUrl =
      'https://github.com/kercre123/vosk-models/raw/main/vosk-model-small-cn-0.22.zip';
  static const String voskCnModelUrlFallback =
      'https://alphacephei.com/vosk/models/vosk-model-small-cn-0.22.zip';
  static const String voskCnModelDir = 'vosk-model-small-cn-0.22';

  /// Vosk 模型目录必备子项（缺任一项 native 加载会失败）。
  static const List<String> voskRequiredEntries = ['am', 'conf', 'graph'];

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
      AppLog.d(_tag, '模型已存在，跳过下载: ${modelDir.path}');
      return modelDir.path;
    }

    final zipPath = p.join(root.path, '$voskCnModelDir.zip');
    try {
      AppLog.d(_tag, '下载主源: $voskCnModelUrl');
      await _download(voskCnModelUrl, zipPath);
    } catch (e) {
      AppLog.w(_tag, '主源失败，回退官方源: $e');
      await _download(voskCnModelUrlFallback, zipPath);
    }
    await _extractZip(zipPath, root.path);
    await File(zipPath).delete();

    await _verifyModelDir(modelDir);
    return modelDir.path;
  }

  /// 从外部 zip 文件导入模型，复制到私有目录并解压，返回模型目录路径。
  ///
  /// 用于网络不可达时的离线导入：用户下载镜像 zip 后通过文件选择器导入。
  static Future<String> importFromZip(String zipPath) async {
    AppLog.d(_tag, '=== 开始导入: $zipPath ===');
    final src = File(zipPath);
    if (!await src.exists()) {
      throw Exception('源文件不存在: $zipPath');
    }
    final srcSize = await src.length();
    AppLog.d(_tag, '源文件大小: ${_mb(srcSize)}');

    final root = await modelsDir();
    AppLog.d(_tag, '模型根目录: ${root.path}');
    final modelDir = Directory(p.join(root.path, voskCnModelDir));

    // 已有模型先清理（避免新旧文件混杂）
    if (await modelDir.exists()) {
      AppLog.d(_tag, '清理旧模型目录: ${modelDir.path}');
      await modelDir.delete(recursive: true);
    }

    final destZip = p.join(root.path, '$voskCnModelDir.zip');
    AppLog.d(_tag, '复制到私有目录: $destZip');
    await src.copy(destZip);
    AppLog.d(_tag, '复制完成，开始解压');

    await _extractZip(destZip, root.path);

    AppLog.d(_tag, '删除临时 zip');
    await File(destZip).delete();

    await _verifyModelDir(modelDir);
    AppLog.d(_tag, '=== 导入完成: ${modelDir.path} ===');
    return modelDir.path;
  }

  static Future<void> _download(String url, String savePath) async {
    final resp = await http.get(Uri.parse(url));
    if (resp.statusCode != 200) {
      throw Exception('模型下载失败: HTTP ${resp.statusCode}');
    }
    await File(savePath).writeAsBytes(resp.bodyBytes, flush: true);
    AppLog.d(_tag, '下载完成: ${_mb(resp.bodyBytes.length)}');
  }

  /// 流式解压（内存恒定，不整包载入）。
  static Future<void> _extractZip(String zipPath, String destDir) async {
    AppLog.d(_tag, '解压 → $destDir（流式）');
    var count = 0;
    await extractFileToDisk(
      zipPath,
      destDir,
      callback: (entry) {
        count++;
        // 只记录较大条目与前若干条，避免日志刷屏
        if (count <= 5 || entry.size > 1024 * 1024) {
          AppLog.d(_tag, '  条目 $count: ${entry.name} (${_mb(entry.size)})');
        }
      },
    );
    AppLog.d(_tag, '解压完成，共 $count 个条目');
  }

  /// 校验模型目录结构，缺失时抛出可读错误（便于定位是 zip 层级问题还是解压失败）。
  static Future<void> _verifyModelDir(Directory modelDir) async {
    if (!await modelDir.exists()) {
      // 列出实际解压出的顶层内容，帮助判断 zip 内层级是否多套一层
      final parent = modelDir.parent;
      final actual =
          await parent.list().map((e) => p.basename(e.path)).toList();
      AppLog.e(_tag, '模型目录缺失，根目录实际内容: $actual');
      throw Exception('未找到模型目录 $voskCnModelDir（解压出: ${actual.join(", ")}）');
    }
    final children =
        await modelDir.list().map((e) => p.basename(e.path)).toList();
    AppLog.d(_tag, '模型目录内容: $children');
    final missing =
        voskRequiredEntries.where((e) => !children.contains(e)).toList();
    if (missing.isNotEmpty) {
      AppLog.e(_tag, '模型目录缺少必备子项: $missing');
      throw Exception('模型不完整，缺少: ${missing.join(", ")}');
    }
  }

  static String _mb(int bytes) =>
      '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
}
