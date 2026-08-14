import 'model_ids.dart';

/// [v2.9.0] 孩子/家长档案。
///
/// 支持多孩子模式：每位孩子拥有独立的学习进度（生词本/知识点/测验记录）。
/// isParent=true 的档案可查看所有孩子数据与设置。
class Profile {
  Profile({
    required this.id,
    required this.name,
    this.avatarEmoji = '👦',
    this.isParent = false,
    required this.createdAt,
  });

  factory Profile.create({
    required String name,
    String avatarEmoji = '👦',
    bool isParent = false,
  }) {
    return Profile(
      id: newModelId('profile'),
      name: name,
      avatarEmoji: avatarEmoji,
      isParent: isParent,
      createdAt: DateTime.now().microsecondsSinceEpoch,
    );
  }

  final String id;
  String name;
  String avatarEmoji;
  bool isParent;
  final int createdAt;

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'avatar_emoji': avatarEmoji,
    'is_parent': isParent ? 1 : 0,
    'created_at': createdAt,
  };

  factory Profile.fromMap(Map<String, dynamic> map) => Profile(
    id: map['id'] as String,
    name: (map['name'] as String?) ?? '',
    avatarEmoji: (map['avatar_emoji'] as String?) ?? '👦',
    isParent: (map['is_parent'] as int?) == 1,
    createdAt: (map['created_at'] as int?) ?? 0,
  );
}
