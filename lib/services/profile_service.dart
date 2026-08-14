import 'package:shared_preferences/shared_preferences.dart';

import '../core/models/profile.dart';
import '../core/storage/database.dart';
import '../core/storage/profile_dao.dart';

/// [v2.9.0] 孩子/家长档案服务：多孩子模式的核心。
///
/// 职责：
/// - 当前活跃档案的选择与持久化（SharedPreferences）
/// - 首次启动时创建默认家长 + 默认孩子档案
/// - 提供 [switchTo] / [current] 供 UI 与 DAO 层使用
class ProfileService {
  ProfileService._internal();

  static final ProfileService instance = ProfileService._internal();

  static const _kCurrentProfileId = 'current_profile_id';

  Profile? _current;
  bool _initDone = false;

  /// 当前活跃档案。调用前请确保 [ensureInitialized]。
  Profile? get current => _current;

  /// 当前档案 ID（DAO 层自动填充用），空=尚未初始化。
  String? get currentProfileId => _current?.id;

  /// 是否已初始化。
  bool get isInitialized => _initDone;

  /// 初始化：读取已保存的当前档案；不存在时创建默认档案。
  Future<void> ensureInitialized() async {
    if (_initDone) return;
    final db = await DatabaseProvider.database;
    final dao = ProfileDao(db);
    final prefs = await SharedPreferences.getInstance();

    final savedId = prefs.getString(_kCurrentProfileId);
    if (savedId != null) {
      final p = await dao.getById(savedId);
      if (p != null) {
        _current = p;
        _initDone = true;
        return;
      }
    }

    // 首次启动：创建家长 + 默认孩子档案
    final existing = await dao.getAll();
    if (existing.isNotEmpty) {
      _current = existing.first;
      await prefs.setString(_kCurrentProfileId, _current!.id);
      _initDone = true;
      return;
    }

    final parent = Profile.create(
      name: '家长',
      avatarEmoji: '👤',
      isParent: true,
    );
    await dao.insert(parent);

    final child = Profile.create(
      name: '小读者',
      avatarEmoji: '👦',
      isParent: false,
    );
    await dao.insert(child);

    _current = child;
    await prefs.setString(_kCurrentProfileId, child.id);
    _initDone = true;
  }

  /// 切换到指定档案（IO 完成后通知监听器）。
  Future<void> switchTo(String profileId) async {
    final db = await DatabaseProvider.database;
    final dao = ProfileDao(db);
    final p = await dao.getById(profileId);
    if (p == null) throw Exception('Profile not found: $profileId');
    _current = p;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCurrentProfileId, profileId);
  }

  /// 获取所有档案（供 UI 展示切换列表）。
  Future<List<Profile>> getAllProfiles() async {
    final db = await DatabaseProvider.database;
    return ProfileDao(db).getAll();
  }

  /// 添加新孩子档案。
  Future<Profile> addChild(String name, {String avatarEmoji = '👦'}) async {
    final db = await DatabaseProvider.database;
    final dao = ProfileDao(db);
    final p = Profile.create(
      name: name,
      avatarEmoji: avatarEmoji,
      isParent: false,
    );
    await dao.insert(p);
    return p;
  }

  /// 删除档案。
  Future<void> deleteProfile(String id) async {
    final db = await DatabaseProvider.database;
    await ProfileDao(db).delete(id);
    if (_current?.id == id) {
      // 切换到第一个可用档案
      final all = await getAllProfiles();
      if (all.isNotEmpty) {
        await switchTo(all.first.id);
      }
    }
  }
}
