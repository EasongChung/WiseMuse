import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// [v0.3.0] 听音选字网格组件（4 选 1）。
///
/// 听写页与章节测验共用，接收选项列表与选中回调。
class CharSelectGrid extends StatelessWidget {
  const CharSelectGrid({
    super.key,
    required this.options,
    this.correctAnswer,
    this.selectedOption,
    this.showResult = false,
    this.onSelect,
    this.onReplay,
    this.isPlaying = false,
  });

  /// 选项列表（通常 4 个）。
  final List<String> options;

  /// 正确答案（显示结果时高亮用）。
  final String? correctAnswer;

  /// 用户已选项。
  final String? selectedOption;

  /// 是否显示结果（正确/错误颜色）。
  final bool showResult;

  /// 选中回调。
  final ValueChanged<String>? onSelect;

  /// 重新播放回调。
  final VoidCallback? onReplay;

  /// TTS 正在播放。
  final bool isPlaying;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          '听发音，选正确的字',
          style: TextStyle(fontSize: 14, color: StudyPalette.inkSoft),
        ),
        const SizedBox(height: 12),

        // 重新播放按钮
        IconButton(
          icon: Icon(
            isPlaying ? Icons.volume_up : Icons.volume_up_outlined,
            size: 48,
            color: StudyPalette.ember,
          ),
          onPressed: isPlaying ? null : onReplay,
          tooltip: '再听一遍',
        ),
        const SizedBox(height: 20),

        // 选项网格
        Wrap(
          spacing: 12,
          runSpacing: 12,
          alignment: WrapAlignment.center,
          children: List.generate(options.length, (i) {
            final opt = options[i];
            final isSelected = selectedOption == opt;
            Color bg;
            Color fg;
            if (showResult) {
              if (opt == correctAnswer) {
                bg = StudyPalette.moss.withValues(alpha: 0.2);
                fg = StudyPalette.moss;
              } else if (isSelected) {
                bg = StudyPalette.ember.withValues(alpha: 0.15);
                fg = StudyPalette.ember;
              } else {
                bg = Colors.white.withValues(alpha: 0.6);
                fg = StudyPalette.inkSoft;
              }
            } else if (isSelected) {
              bg = StudyPalette.emberSoft;
              fg = StudyPalette.ember;
            } else {
              bg = Colors.white.withValues(alpha: 0.6);
              fg = StudyPalette.ink;
            }

            return SizedBox(
              width: 72,
              height: 72,
              child: Material(
                color: bg,
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: showResult ? null : () => onSelect?.call(opt),
                  child: Center(
                    child: Text(
                      opt,
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        color: fg,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ],
    );
  }
}
