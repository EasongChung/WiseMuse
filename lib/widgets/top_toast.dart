import 'package:flutter/material.dart';

/// [v0.1.53] 顶部 Toast 工具：在屏幕顶部显示短提示，替换底部 SnackBar。
///
/// 用法：
/// ```dart
/// TopToast.show(context, '消息内容');
/// TopToast.show(context, '⚠️ 警告消息', isWarning: true);
/// ```
class TopToast {
  TopToast._();

  /// 在屏幕顶部显示一个短暂提示。
  ///
  /// [context] 当前 Widget 上下文；[message] 提示文字；
  /// [duration] 显示时长（默认 2.5 秒）；[isWarning] 是否警告风格（红色强调）。
  static void show(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 3),
    bool isWarning = false,
  }) {
    final overlay = Overlay.of(context);
    late OverlayEntry entry;

    entry = OverlayEntry(
      builder: (ctx) {
        return _TopToastWidget(
          message: message,
          isWarning: isWarning,
          onDismiss: () => entry.remove(),
        );
      },
    );

    overlay.insert(entry);

    Future.delayed(duration, () {
      if (entry.mounted) entry.remove();
    });
  }
}

class _TopToastWidget extends StatefulWidget {
  const _TopToastWidget({
    required this.message,
    required this.isWarning,
    required this.onDismiss,
  });

  final String message;
  final bool isWarning;
  final VoidCallback onDismiss;

  @override
  State<_TopToastWidget> createState() => _TopToastWidgetState();
}

class _TopToastWidgetState extends State<_TopToastWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _opacity = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _slide = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.elasticOut));
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _dismiss() {
    _controller.reverse().then((_) {
      widget.onDismiss();
    });
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.of(context).padding;
    final top = padding.top + 8;

    return Positioned(
      top: top,
      left: 16,
      right: 16,
      child: SlideTransition(
        position: _slide,
        child: FadeTransition(
          opacity: _opacity,
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(12),
            color:
                widget.isWarning
                    ? Colors.red.shade700
                    : const Color(0xFF4A3728), // StudyPalette.ink 深棕
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _dismiss,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(
                      widget.isWarning
                          ? Icons.warning_amber_rounded
                          : Icons.check_circle_outline,
                      size: 18,
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.message,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          height: 1.4,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: _dismiss,
                      child: Icon(
                        Icons.close,
                        size: 16,
                        color: Colors.white.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
