import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wisemuse/core/settings/settings_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('默认值', () async {
    final s = SettingsService.instance;
    expect(await s.getApiBaseUrl(), isNull);
    expect(await s.isApiConfigured(), false);
    expect(await s.getTtsRate(), 0.9); // 儿童慢速默认
    expect(await s.getTtsRepeatCount(), 1);
    expect(await s.getTtsPauseMs(), 300);
    expect(await s.getPreferOffline(), false);
  });

  test('API 配置读写与完整性判定', () async {
    final s = SettingsService.instance;
    await s.setApiBaseUrl('https://api.example.com/v1');
    await s.setApiModel('qwen-vl');
    expect(await s.isApiConfigured(), false); // key 未填
    await s.setApiKey('sk-test');
    expect(await s.isApiConfigured(), true);
    expect(await s.getApiBaseUrl(), 'https://api.example.com/v1');
    expect(await s.getApiModel(), 'qwen-vl');
  });

  test('朗读参数与离线开关读写', () async {
    final s = SettingsService.instance;
    await s.setTtsRate(1.2);
    await s.setTtsRepeatCount(3);
    await s.setTtsPauseMs(500);
    await s.setPreferOffline(true);
    expect(await s.getTtsRate(), 1.2);
    expect(await s.getTtsRepeatCount(), 3);
    expect(await s.getTtsPauseMs(), 500);
    expect(await s.getPreferOffline(), true);
  });

  test('翻译语种默认值', () async {
    final s = SettingsService.instance;
    expect(await s.getTranslationSource(), 'auto');
    expect(await s.getTranslationTarget(), 'en');
  });

  test('翻译语种读写', () async {
    final s = SettingsService.instance;
    await s.setTranslationSource('zh');
    await s.setTranslationTarget('ja');
    expect(await s.getTranslationSource(), 'zh');
    expect(await s.getTranslationTarget(), 'ja');
  });
}
