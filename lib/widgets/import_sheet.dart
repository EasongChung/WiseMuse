import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/debug/app_log.dart';

/// [v0.2.0] 导入入口底部弹窗：拍照识别 / 从相册选图 / 选择文档。
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
    return showModalBottomSheet<ImportAction>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  '导入教材',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('拍照识别'),
                subtitle: const Text('拍摄课本/资料页'),
                onTap: () => Navigator.of(context).pop(ImportAction.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('从相册选图'),
                subtitle: const Text('选择已保存的图片'),
                onTap: () => Navigator.of(context).pop(ImportAction.gallery),
              ),
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: const Text('选择文档'),
                subtitle: const Text('Word / PDF / TXT'),
                onTap: () => Navigator.of(context).pop(ImportAction.file),
              ),
              const SizedBox(height: 8),
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
