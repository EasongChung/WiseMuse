import 'package:flutter/services.dart';

import '../core/debug/app_log.dart';

/// [v0.2.0] 拍照/相册选取桥（MethodChannel → PickerBridge.kt）。
///
/// 系统 intent（ACTION_GET_CONTENT / ACTION_IMAGE_CAPTURE），结果由原生侧
/// 复制到 app 私有目录后返回文件路径。用户取消返回 null。
class PickerService {
  static const _tag = 'picker';
  static const _channel = MethodChannel('com.zqpd.wisemuse/picker');

  /// 从相册选图；返回已复制到私有目录的路径；用户取消返回 null。
  Future<String?> pickFromGallery() async {
    try {
      final path = await _channel.invokeMethod<String>('pickFromGallery');
      if (path == null) AppLog.d(_tag, '相册选取已取消');
      return path;
    } catch (e) {
      AppLog.e(_tag, 'pickFromGallery 失败: $e');
      return null;
    }
  }

  /// 拍照；返回已复制到私有目录的路径；用户取消返回 null。
  Future<String?> pickFromCamera() async {
    try {
      final path = await _channel.invokeMethod<String>('pickFromCamera');
      if (path == null) AppLog.d(_tag, '拍照已取消');
      return path;
    } catch (e) {
      AppLog.e(_tag, 'pickFromCamera 失败: $e');
      return null;
    }
  }
}
