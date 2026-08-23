/// 系统 TTS 音色元数据。
class TtsVoiceInfo {
  const TtsVoiceInfo({
    required this.name,
    required this.locale,
    required this.language,
    required this.country,
    required this.displayLanguage,
    required this.displayName,
    this.isNetworkConnectionRequired = false,
    this.quality = 300,
  });

  final String name;
  final String locale;
  final String language;
  final String country;
  final String displayLanguage;
  final String displayName;
  final bool isNetworkConnectionRequired;
  final int quality;

  /// 是否为中文音色（含普通话、大陆、台湾等）。
  bool get isChinese =>
      language.toLowerCase() == 'zh' ||
      language.toLowerCase() == 'cmn' ||
      locale.toLowerCase().startsWith('zh');

  /// 是否为粤语音色。
  bool get isCantonese =>
      locale.toLowerCase().contains('yue') ||
      locale.toLowerCase().contains('zh-hk') ||
      locale.toLowerCase().contains('zh_hk');

  /// 是否为英语音色。
  bool get isEnglish =>
      language.toLowerCase() == 'en' || locale.toLowerCase().startsWith('en');

  /// 面向用户的友好展示文案。
  String get readableLabel {
    final cleanName = name
        .replaceAll(
          RegExp(r'^(cmn|zh|en)[_-][a-z0-9_-]+[_-]x[_-]', caseSensitive: false),
          '',
        )
        .replaceAll('_', ' ');
    if (isCantonese) return '粤语 · $cleanName';
    if (isChinese) return '中文 · $cleanName';
    if (isEnglish) return '英文 · $cleanName';
    return '$displayLanguage · $cleanName';
  }

  factory TtsVoiceInfo.fromMap(Map<dynamic, dynamic> map) => TtsVoiceInfo(
    name: (map['name'] as String?) ?? '',
    locale: (map['locale'] as String?) ?? '',
    language: (map['language'] as String?) ?? '',
    country: (map['country'] as String?) ?? '',
    displayLanguage: (map['displayLanguage'] as String?) ?? '',
    displayName: (map['displayName'] as String?) ?? '',
    isNetworkConnectionRequired:
        (map['isNetworkConnectionRequired'] as bool?) ?? false,
    quality: (map['quality'] as int?) ?? 300,
  );

  Map<String, dynamic> toMap() => {
    'name': name,
    'locale': locale,
    'language': language,
    'country': country,
    'displayLanguage': displayLanguage,
    'displayName': displayName,
    'isNetworkConnectionRequired': isNetworkConnectionRequired,
    'quality': quality,
  };
}
