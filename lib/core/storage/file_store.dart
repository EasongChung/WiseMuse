import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// [v0.1.0] 文件存储：原文件 / 导出文件管理（app 私有目录）。
///
/// 拍照/相册/选择文件复制进私有原文件目录，避免直接引用外部 URI
/// （分区存储限制下外部文件随时可能失效）。

class FileStore {
  FileStore._();

  /// 原文件根目录：`{documents}/originals`。
  static Future<Directory> originalsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'originals'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 把外部文件复制到私有原文件目录，返回新路径。
  ///
  /// [ext] 不含点的扩展名（如 `jpg`、`pdf`、`docx`）。
  static Future<String> copyToOriginals(String srcPath, String ext) async {
    final dir = await originalsDir();
    final name = 'orig_${DateTime.now().microsecondsSinceEpoch}.$ext';
    final dest = p.join(dir.path, name);
    await File(srcPath).copy(dest);
    return dest;
  }

  /// 删除私有目录下的文件（幂等）。
  static Future<void> delete(String path) async {
    final f = File(path);
    if (await f.exists()) await f.delete();
  }
}
