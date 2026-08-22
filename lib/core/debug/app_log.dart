import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// [v0.1.0] 测试期内置日志工具。
///
/// [v0.1.53] 增强日志：新增 [caller] 字段（文件名:行号:函数名），
/// 便于从日志中定位代码位置。`d`/`w`/`e` 自动提取调用方信息。
///
/// 设计要点（进程可能被系统 OOM 直接 kill，内存缓冲会全部丢失）：
/// - 日志**同步追加**写入 `{documents}/logs/app.log`，重启后仍可读回崩溃前最后一步；
/// - 内存环形缓冲（最近 [kBufferLines] 行）供日志页实时展示；
/// - 接管 Flutter/Dart 全局错误回调，未捕获异常也落盘；
/// - 测试阶段默认启用，正式版可通过 [enabled] 关闭。
class AppLog {
  AppLog._();

  /// 内存缓冲上限（行）。
  static const int kBufferLines = 500;

  /// 日志文件轮转阈值（超过则清零重来）。
  static const int kMaxFileBytes = 4 * 1024 * 1024;

  /// 是否落盘（测试阶段常开）。
  static bool enabled = true;

  /// 最近日志，供日志页实时展示。
  static final ValueNotifier<List<LogEntry>> entries =
      ValueNotifier<List<LogEntry>>(const []);

  static File? _file;
  static bool _inited = false;

  /// 日志文件路径（未初始化成功时为 null）。
  static String? get filePath => _file?.path;

  /// 初始化：建日志文件 + 接管全局错误回调。幂等。
  static Future<void> init() async {
    if (_inited) return;
    _inited = true;
    WidgetsFlutterBinding.ensureInitialized();

    FlutterError.onError = (details) {
      _writeSync('error', 'flutter', '${details.exception}\n${details.stack}');
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      _writeSync('fatal', 'zone', '$error\n$stack');
      return true; // 已记录，不再上抛
    };

    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'logs'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final f = File(p.join(dir.path, 'app.log'));
      if (await f.exists() && await f.length() > kMaxFileBytes) {
        await f.delete();
      }
      _file = f;
      d('app_log', '===== 启动 ===== 日志文件: ${f.path}');
    } catch (e) {
      _file = null; // documents 不可用时降级为仅内存
      w('app_log', '日志文件初始化失败，降级为仅内存: $e');
    }
  }

  /// [v0.1.53] 记录 debug 日志，自动提取调用方位置。
  /// [context] 附加 KV 对（如入参/出参摘要），格式化为 `[key=val ...]` 追加到消息。
  static void d(String tag, String message, [Map<String, dynamic>? context]) =>
      _writeSync('debug', tag, message, _callerInfo(), context);

  /// [v0.1.53] 记录 warn 日志，自动提取调用方位置。
  static void w(String tag, String message, [Map<String, dynamic>? context]) =>
      _writeSync('warn', tag, message, _callerInfo(), context);

  /// [v0.1.53] 记录 error 日志，自动提取调用方位置。
  static void e(String tag, String message, [Map<String, dynamic>? context]) =>
      _writeSync('error', tag, message, _callerInfo(), context);

  /// [v0.1.53] 从堆栈提取调用方信息（文件:行号:函数）。
  static String _callerInfo() {
    try {
      final stack = StackTrace.current;
      final frames = stack.toString().split('\n');
      // frames[0] = _callerInfo 自身, frames[1] = d/w/e, frames[2] = 调用方
      for (var i = 0; i < frames.length && i < 6; i++) {
        final line = frames[i].trim();
        // 跳过框架自身、app_log 内部和 dart:core
        if (line.contains('app_log.dart') || line.contains('dart:')) continue;
        if (line.startsWith('#')) {
          // 格式: #2      _someMethod (package:wisemuse/...)
          final m = RegExp(r'\(([^)]+)\)').firstMatch(line);
          if (m != null) {
            final loc = m.group(1)!;
            // 提取文件名和行号: package:wisemuse/features/reader/reader_page.dart:123
            final locM = RegExp(r'([^/]+\.dart):(\d+)').firstMatch(loc);
            if (locM != null) {
              return '${locM.group(1)}:${locM.group(2)}';
            }
          }
        }
      }
    } catch (_) {}
    return '';
  }

  /// 清空日志文件与内存缓冲。
  static Future<void> clear() async {
    entries.value = const [];
    try {
      final f = _file;
      if (f != null && await f.exists()) {
        await f.writeAsString('', flush: true);
      }
    } catch (_) {
      // 清空失败忽略
    }
    d('app_log', '===== 日志已清空 =====');
  }

  static void _writeSync(
    String level,
    String tag,
    String message, [
    String caller = '',
    Map<String, dynamic>? context,
  ]) {
    final ctxStr = _formatContext(context);
    final fullMessage = ctxStr.isNotEmpty ? '$message $ctxStr' : message;
    for (final line in fullMessage.split('\n')) {
      final t = _stamp();
      final entry = LogEntry(
        t: t,
        level: level,
        tag: tag,
        message: line,
        caller: caller,
        context: ctxStr,
      );
      final buf =
          entries.value.length >= kBufferLines
              ? entries.value.sublist(entries.value.length - kBufferLines + 1)
              : entries.value;
      entries.value = [...buf, entry];

      if (!kReleaseMode) {
        final callerStr = caller.isNotEmpty ? ' $caller' : '';
        debugPrint('[$tag]$callerStr$ctxStr $line');
      }
      if (!enabled) continue;
      try {
        final callerStr = caller.isNotEmpty ? ' $caller' : '';
        _file?.writeAsStringSync(
          '$t [$level] [$tag]$callerStr$ctxStr $line\n',
          mode: FileMode.append,
          flush: true, // 关键：flush 后才能在进程被 kill 时保住这一行
        );
      } catch (_) {
        // 磁盘写失败（空间满/文件被删）降级为仅内存
      }
    }
  }

  /// 将 [context] KV 对格式化为 `[key=val ...]` 字符串；空则返回空串。
  /// 值若是 Map/List 则 JSON 化，其余 `toString()`；长度截断到 200 字符防刷屏。
  static String _formatContext(Map<String, dynamic>? context) {
    if (context == null || context.isEmpty) return '';
    final parts = <String>[];
    for (final entry in context.entries) {
      final v = entry.value;
      final s =
          (v is Map || v is List)
              ? (() {
                try {
                  return v.toString();
                } catch (_) {
                  return '?';
                }
              })()
              : v.toString();
      parts.add(
        '${entry.key}=${s.length > 200 ? '${s.substring(0, 200)}…' : s}',
      );
    }
    return '[${parts.join(' ')}]';
  }

  static String _stamp() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(n.hour)}:${two(n.minute)}:${two(n.second)}'
        '.${n.millisecond.toString().padLeft(3, '0')}';
  }

  /// 导出当前内存缓冲为纯文本（复制/分享用）。
  static String toText() {
    final sb = StringBuffer();
    for (final e in entries.value) {
      final callerStr = e.caller.isNotEmpty ? ' ${e.caller}' : '';
      final ctxStr = e.context.isNotEmpty ? ' ${e.context}' : '';
      sb.writeln(
        '${e.t} [${e.level}] [${e.tag}]$callerStr$ctxStr ${e.message}',
      );
    }
    return sb.toString();
  }

  /// 读取磁盘日志全文（含上次崩溃前的记录）。
  static Future<String> readFile() async {
    try {
      final f = _file;
      if (f != null && await f.exists()) return f.readAsString();
    } catch (e) {
      return '读取日志文件失败: $e';
    }
    return '（无日志文件）';
  }
}

/// 单条日志。
class LogEntry {
  const LogEntry({
    required this.t,
    required this.level,
    required this.tag,
    required this.message,
    this.caller = '', // [v0.1.53] 调用方位置（文件:行号）
    this.context = '', // [v0.1.57] 附加 KV 对（如入参/出参摘要）
  });

  final String t;
  final String level;
  final String tag;
  final String message;

  /// [v0.1.53] 调用方位置（文件名:行号），空串表示无。
  final String caller;

  /// [v0.1.57] 附加 KV 对格式化串（如 `[model=qwen2.5 tokens=128]`），空串表示无。
  final String context;
}
