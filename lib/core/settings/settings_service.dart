import 'package:shared_preferences/shared_preferences.dart';

/// [v0.1.0] 设置服务：API 配置 / 朗读参数 / 离线开关（KV 存储）。
///
/// 键名常量供 UI 与测试引用；读取均带默认值兜底。

class SettingsService {
  SettingsService._();

  /// 单例（无状态，底层走 SharedPreferences 单例）。
  static final SettingsService instance = SettingsService._();

  // ---- 键名 ----
  static const kApiBaseUrl = 'api_base_url';
  static const kApiKey = 'api_key';
  static const kApiModel = 'api_model';
  static const kTtsRate = 'tts_rate';
  static const kTtsRepeatCount = 'tts_repeat_count';
  static const kTtsPauseMs = 'tts_pause_ms';
  static const kPreferOffline = 'prefer_offline';

  // ---- 翻译引擎 ----
  /// 翻译引擎类型（[TranslationEngineType] 的 name：mlkit/llm/cloud/auto）。
  /// 默认 auto（三级回落）。
  static const kTranslationEngine = 'translation_engine';

  // ---- API 配置 ----
  Future<String?> getApiBaseUrl() async =>
      (await SharedPreferences.getInstance()).getString(kApiBaseUrl);
  Future<void> setApiBaseUrl(String v) async =>
      (await SharedPreferences.getInstance()).setString(kApiBaseUrl, v);

  Future<String?> getApiKey() async =>
      (await SharedPreferences.getInstance()).getString(kApiKey);
  Future<void> setApiKey(String v) async =>
      (await SharedPreferences.getInstance()).setString(kApiKey, v);

  Future<String?> getApiModel() async =>
      (await SharedPreferences.getInstance()).getString(kApiModel);
  Future<void> setApiModel(String v) async =>
      (await SharedPreferences.getInstance()).setString(kApiModel, v);

  /// API 是否已配置完整（baseUrl + key + model）。
  Future<bool> isApiConfigured() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(kApiBaseUrl) ?? '';
    final key = prefs.getString(kApiKey) ?? '';
    final model = prefs.getString(kApiModel) ?? '';
    return url.isNotEmpty && key.isNotEmpty && model.isNotEmpty;
  }

  // ---- 朗读参数 ----
  /// 语速（flutter_tts 0.5-2.0），默认 0.9（儿童慢速）。
  Future<double> getTtsRate() async =>
      (await SharedPreferences.getInstance()).getDouble(kTtsRate) ?? 0.9;
  Future<void> setTtsRate(double v) async =>
      (await SharedPreferences.getInstance()).setDouble(kTtsRate, v);

  /// 听写/跟读重复遍数，默认 1。
  Future<int> getTtsRepeatCount() async =>
      (await SharedPreferences.getInstance()).getInt(kTtsRepeatCount) ?? 1;
  Future<void> setTtsRepeatCount(int v) async =>
      (await SharedPreferences.getInstance()).setInt(kTtsRepeatCount, v);

  /// 句间停顿（毫秒），默认 300。
  Future<int> getTtsPauseMs() async =>
      (await SharedPreferences.getInstance()).getInt(kTtsPauseMs) ?? 300;
  Future<void> setTtsPauseMs(int v) async =>
      (await SharedPreferences.getInstance()).setInt(kTtsPauseMs, v);

  // ---- 离线开关 ----
  /// 是否优先离线（AI 助教/识别），默认 false（在线优先）。
  Future<bool> getPreferOffline() async =>
      (await SharedPreferences.getInstance()).getBool(kPreferOffline) ?? false;
  Future<void> setPreferOffline(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(kPreferOffline, v);

  // ---- 翻译引擎 ----
  /// 当前翻译引擎类型（默认 auto）。
  Future<String> getTranslationEngine() async =>
      (await SharedPreferences.getInstance()).getString(kTranslationEngine) ??
      'auto';
  Future<void> setTranslationEngine(String v) async =>
      (await SharedPreferences.getInstance()).setString(kTranslationEngine, v);
}
