import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/debug/app_log.dart';
import '../core/theme/app_theme.dart';

/// [v0.3.0] 导入入口底部弹窗（「暖色书房」风格）：拍照识别 / 从相册选图 / 选择文档。
///
/// 三个动作各自返回结果类型由调用方决定（拍照/相册给路径，文档给 FilePickerResult）。
/// 调用方 await 本弹窗，根据返回值继续导入流程。
///
/// 返回值约定：
/// - `ImportAction.camera`  → 后续调用 PickerService().pickFromCamera()
/// - `ImportAction.gallery` → 后续调用 PickerService().pickFromGallery()
/// - `ImportAction.file`    → 后续调用 FilePicker 选文档
/// - null → 用户关闭弹窗
enum ImportAction { camera, gallery, file }

class ImportSheet {
  static const _tag = 'import';

  /// 展示导入方式选择弹窗，返回用户选择；关闭返回 null。
  static Future<ImportAction?> show(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return showModalBottomSheet<ImportAction>(
      context: context,
      backgroundColor: isDark ? StudyPalette.darkCard : StudyPalette.parchment,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 顶部抓手
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                decoration: BoxDecoration(
                  color: StudyPalette.linen,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('放入一本新书', style: titleStyle(fontSize: 18)),
                ),
              ),
              const SizedBox(height: 8),
              _ImportOption(
                icon: Icons.photo_camera_outlined,
                color: StudyPalette.spineImage,
                title: '拍照识别',
                subtitle: '拍摄课本或资料页',
                onTap: () => Navigator.of(context).pop(ImportAction.camera),
              ),
              _ImportOption(
                icon: Icons.photo_library_outlined,
                color: StudyPalette.spineImage,
                title: '从相册选图',
                subtitle: '选择已保存的图片',
                onTap: () => Navigator.of(context).pop(ImportAction.gallery),
              ),
              _ImportOption(
                icon: Icons.description_outlined,
                color: StudyPalette.spinePdf,
                title: '选择文档',
                subtitle: 'Word / PDF / TXT',
                onTap: () => Navigator.of(context).pop(ImportAction.file),
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  /// 选择文档文件（Word/PDF/TXT/MD）。
  static Future<FilePickerResult?> pickDocument() {
    AppLog.d(_tag, '打开文件选择器');
    return FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf', 'docx', 'txt', 'md'],
    );
  }
}

/// 导入选项行：圆角图标块（来源色）+ 标题 + 副标题。
class _ImportOption extends StatelessWidget {
  const _ImportOption({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: color, size: 24),
      ),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 15,
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
