import 'package:flutter/material.dart';

import '../../core/models/profile.dart';
import '../../core/theme/app_theme.dart';
import '../../services/profile_service.dart';
import '../debug/log_page.dart';
import '../rag/rag_management_page.dart';
import '../settings/settings_page.dart';
import '../wordbook/wordbook_page.dart';
import '../../widgets/top_toast.dart';

/// [v0.3.0] 个人中心页（我的 Tab）。
/// [v0.1.35] 多孩子模式：顶部显示当前孩子头像+名称，点击切换；
///         右下家长入口齿轮图标，家长模式可访问设置。
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  Profile? _currentProfile;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await ProfileService.instance.ensureInitialized();
    if (!mounted) return;
    setState(() {
      _currentProfile = ProfileService.instance.current;
      _loaded = true;
    });
  }

  Future<void> _switchProfile(String profileId) async {
    await ProfileService.instance.switchTo(profileId);
    if (!mounted) return;
    setState(() => _currentProfile = ProfileService.instance.current);
  }

  void _showProfilePicker() async {
    final all = await ProfileService.instance.getAllProfiles();
    if (!mounted || all.isEmpty) return;

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: StudyPalette.parchment,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        // 使用 StatefulBuilder 让内部按钮更新不重建整个页面
        return StatefulBuilder(
          builder:
              (ctx, setSheet) => Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Center(
                      child: SizedBox(
                        width: 32,
                        height: 4,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: StudyPalette.linen,
                            borderRadius: BorderRadius.all(Radius.circular(2)),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text('切换档案', style: titleStyle(fontSize: 16)),
                    const SizedBox(height: 8),
                    ...all.map(
                      (p) => ListTile(
                        dense: true,
                        leading: Text(
                          p.avatarEmoji,
                          style: const TextStyle(fontSize: 28),
                        ),
                        title: Text(
                          p.name,
                          style: TextStyle(
                            fontWeight:
                                _currentProfile?.id == p.id
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                            color: StudyPalette.onSurfaceResolved(context),
                          ),
                        ),
                        subtitle: Text(
                          p.isParent ? '家长' : '孩子',
                          style: const TextStyle(
                            fontSize: 12,
                            color: StudyPalette.inkSoft,
                          ),
                        ),
                        trailing:
                            _currentProfile?.id == p.id
                                ? const Icon(
                                  Icons.check,
                                  color: StudyPalette.moss,
                                  size: 20,
                                )
                                : null,
                        onTap: () {
                          if (_currentProfile?.id != p.id) {
                            _switchProfile(p.id);
                          }
                          Navigator.of(ctx).pop();
                        },
                      ),
                    ),
                    const Divider(indent: 16),
                    TextButton.icon(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _addChild();
                      },
                      icon: const Icon(Icons.person_add_outlined, size: 18),
                      label: const Text('添加孩子档案'),
                    ),
                  ],
                ),
              ),
        );
      },
    );
  }

  void _addChild() async {
    final nameCtrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: StudyPalette.parchment,
            title: const Text('添加孩子档案'),
            content: TextField(
              controller: nameCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '孩子昵称',
                hintText: '如：小明',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(nameCtrl.text.trim()),
                child: const Text('添加'),
              ),
            ],
          ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    await ProfileService.instance.addChild(name);
    // 切换到新孩子档案
    final all = await ProfileService.instance.getAllProfiles();
    if (all.isNotEmpty && mounted) {
      await _switchProfile(all.last.id);
    }
  }

  // ===== Build =====

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bug_report_outlined),
            tooltip: '运行日志',
            onPressed:
                () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const LogPage())),
          ),
        ],
      ),
      body:
          _loaded
              ? _buildBody()
              : const Center(child: CircularProgressIndicator()),
    );
  }

  Widget _buildBody() {
    final p = _currentProfile;
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 头像区域 — 点击弹出档案切换
              Center(
                child: GestureDetector(
                  onTap: _showProfilePicker,
                  child: Column(
                    children: [
                      CircleAvatar(
                        radius: 36,
                        backgroundColor: StudyPalette.emberSoft,
                        child: Text(
                          p?.avatarEmoji ?? '👤',
                          style: const TextStyle(fontSize: 36),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        p?.name ?? '小读者',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: StudyPalette.onSurfaceResolved(context),
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        '点击切换档案',
                        style: TextStyle(
                          fontSize: 12,
                          color: StudyPalette.inkSoft,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 28),

              // 功能入口列表
              Card(
                child: Column(
                  children: [
                    _buildEntry(
                      context,
                      icon: Icons.menu_book_outlined,
                      title: '生词本',
                      subtitle: '查看和管理不熟悉的词语',
                      onTap:
                          () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const WordBookPage(),
                            ),
                          ),
                    ),
                    const Divider(height: 1, indent: 56),
                    _buildEntry(
                      context,
                      icon: Icons.psychology_outlined,
                      title: 'RAG 知识库',
                      subtitle: '管理书籍向量索引与原文切片',
                      onTap:
                          () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const RagManagementPage(),
                            ),
                          ),
                    ),
                    const Divider(height: 1, indent: 56),
                    _buildEntry(
                      context,
                      icon: Icons.bar_chart_outlined,
                      title: '学习统计',
                      subtitle: '学习记录与进度',
                      onTap: () {
                        TopToast.show(context, '学习统计即将推出');
                      },
                    ),
                    const Divider(height: 1, indent: 56),
                    _buildEntry(
                      context,
                      icon: Icons.bug_report_outlined,
                      title: '运行日志',
                      subtitle: '查看应用运行日志',
                      onTap:
                          () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const LogPage()),
                          ),
                    ),
                    const Divider(height: 1, indent: 56),
                    _buildEntry(
                      context,
                      icon: Icons.settings_outlined,
                      title: '设置',
                      subtitle: '翻译引擎、朗读参数、AI 配置',
                      onTap:
                          () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const SettingsPage(),
                            ),
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // [v0.1.35] 右下家长入口齿轮 — 仅家长模式可见
        if (p?.isParent == true)
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton.small(
              heroTag: 'parentEntry',
              backgroundColor: StudyPalette.emberSoft,
              onPressed: _showParentPanel,
              child: const Icon(
                Icons.admin_panel_settings,
                color: StudyPalette.ember,
              ),
            ),
          ),
      ],
    );
  }

  void _showParentPanel() {
    showModalBottomSheet(
      context: context,
      backgroundColor: StudyPalette.parchment,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder:
          (ctx) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Center(
                  child: SizedBox(
                    width: 32,
                    height: 4,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: StudyPalette.linen,
                        borderRadius: BorderRadius.all(Radius.circular(2)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text('家长控制', style: titleStyle(fontSize: 16)),
                const SizedBox(height: 8),
                ListTile(
                  dense: true,
                  leading: const Icon(
                    Icons.settings,
                    color: StudyPalette.ember,
                  ),
                  title: const Text('应用设置'),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SettingsPage()),
                    );
                  },
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(
                    Icons.people_outline,
                    color: StudyPalette.ember,
                  ),
                  title: const Text('管理孩子档案'),
                  subtitle: const Text('添加/删除孩子'),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _showProfilePicker();
                  },
                ),
              ],
            ),
          ),
    );
  }

  Widget _buildEntry(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon, color: StudyPalette.ember, size: 24),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: StudyPalette.onSurfaceResolved(context),
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontSize: 12, color: StudyPalette.inkSoft),
      ),
      trailing: const Icon(Icons.chevron_right, color: StudyPalette.inkSoft),
      onTap: onTap,
    );
  }
}
