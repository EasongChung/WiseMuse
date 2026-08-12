import 'package:flutter/services.dart';

import '../core/debug/app_log.dart';

/// [v0.3.0] ML Kit 翻译 + 语种识别服务（MethodChannel → TranslationBridge.kt）。
///
/// 翻译模型从 Google CDN 直连下载（~30MB/语对），**不经 Google Play Services**，
/// 无 GMS 机型可用。下载后持久化在 app 存储空间，离线可用。
/// 语种识别（[identifyLanguage]）模型随 AAR 打包，无需下载。
///
/// **不会抛异常**，失败统一返回 null。调用方（[TranslationEngine]）负责回落。
class MlKitTranslationService {
  static const _tag = 'mlkit_translate';
  static const _channel = MethodChannel('com.zqpd.wisemuse/translate');

  /// 翻译 [text] 从 [source] 到 [target]。
  ///
  /// [source]/[target] 为 BCP-47 代码（如 `zh`/`en`/`ja`）。
  /// 翻译模型未下载时自动下载（默认仅 WiFi），下载成功才翻译。
  /// 失败返回 null。
  Future<String?> translate({
    required String text,
    required String source,
    required String target,
  }) async {
    try {
      final result = await _channel.invokeMethod<String>('translate', {
        'text': text,
        'source': source,
        'target': target,
      });
      return result;
    } catch (e) {
      AppLog.e(_tag, 'translate 失败: $e');
      return null;
    }
  }

  /// 检查 [lang] 的翻译模型是否已下载。
  Future<bool> isModelDownloaded(String lang) async {
    try {
      final ok = await _channel.invokeMethod<bool>('isModelDownloaded', {
        'lang': lang,
      });
      return ok ?? false;
    } catch (e) {
      AppLog.e(_tag, 'isModelDownloaded($lang) 失败: $e');
      return false;
    }
  }

  /// 下载 [lang] 的翻译模型。
  /// [wifiRequired] 默认 true（仅 WiFi 下载）。成功返回 true。
  Future<bool> downloadModel(String lang, {bool wifiRequired = true}) async {
    try {
      final ok = await _channel.invokeMethod<bool>('downloadModel', {
        'lang': lang,
        'wifiRequired': wifiRequired,
      });
      return ok ?? false;
    } catch (e) {
      AppLog.e(_tag, 'downloadModel($lang) 失败: $e');
      return false;
    }
  }

  /// 删除 [lang] 的翻译模型以释放存储空间。
  Future<bool> deleteModel(String lang) async {
    try {
      final ok = await _channel.invokeMethod<bool>('deleteModel', {
        'lang': lang,
      });
      return ok ?? false;
    } catch (e) {
      AppLog.e(_tag, 'deleteModel($lang) 失败: $e');
      return false;
    }
  }

  /// 识别 [text] 的语种，返回 BCP-47 代码（如 `zh`/`en`）。
  /// 识别失败返回 `und`（undetermined）。
  Future<String> identifyLanguage(String text) async {
    try {
      final lang = await _channel.invokeMethod<String>('identifyLanguage', {
        'text': text,
      });
      return lang ?? 'und';
    } catch (e) {
      AppLog.e(_tag, 'identifyLanguage 失败: $e');
      return 'und';
    }
  }
}
