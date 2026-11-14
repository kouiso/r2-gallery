import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

class ViewerFooterAction {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool danger;
  final bool accent;
  const ViewerFooterAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
    this.accent = false,
  });
}

/// 作品操作と再生操作が同じ下端を使うため、文字の折返しを含む高さを先に共有する。
class ViewerFooterLayout {
  static const minimumRowHeight = 76.0;
  static const labelStyle = TextStyle(fontSize: 12, height: 1.2);
  final int columns;
  final double rowHeight;
  final int rows;
  final TextStyle textStyle;
  const ViewerFooterLayout._(
      this.columns, this.rowHeight, this.rows, this.textStyle);

  double get height => rows * rowHeight;

  factory ViewerFooterLayout.measure({
    required List<ViewerFooterAction> actions,
    required double width,
    required TextScaler textScaler,
    required TextDirection textDirection,
    TextStyle textStyle = labelStyle,
  }) {
    assert(actions.isNotEmpty);
    var columns = math.max(1, math.min(actions.length, width ~/ 48));
    var textHeight = 0.0;
    while (true) {
      var fits = true;
      textHeight = 0;
      for (final action in actions) {
        final text = TextPainter(
          text: TextSpan(text: action.label, style: textStyle),
          textScaler: textScaler,
          textDirection: textDirection,
          maxLines: 2,
        )..layout(maxWidth: math.max(1.0, width / columns - 16));
        fits = fits && !text.didExceedMaxLines;
        textHeight = math.max(textHeight, text.height);
        text.dispose();
      }
      if (fits || columns == 1) break;
      // ラベルを省略して意味を失わせず、押せる幅を保ったまま段を増やす。
      columns--;
    }
    final rowHeight = math.max(minimumRowHeight, 24 + 4 + textHeight + 16)
        .ceilToDouble();
    return ViewerFooterLayout._(
        columns, rowHeight, (actions.length + columns - 1) ~/ columns, textStyle);
  }
}

class ViewerFooter extends StatelessWidget {
  final List<ViewerFooterAction> actions;
  final ViewerFooterLayout layout;
  const ViewerFooter({super.key, required this.actions, required this.layout});

  @override
  Widget build(BuildContext context) => Material(
        key: const ValueKey('viewer-actions'),
        color: const Color(0xCC000000),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var row = 0; row < layout.rows; row++)
                SizedBox(
                  height: layout.rowHeight,
                  child: Row(children: [
                    for (var column = 0; column < layout.columns; column++)
                      Expanded(
                        child: row * layout.columns + column < actions.length
                            ? _FooterButton(
                                action: actions[row * layout.columns + column],
                                textStyle: layout.textStyle)
                            : const SizedBox.shrink(),
                      ),
                  ]),
                ),
            ],
          ),
        ),
      );
}

class _FooterButton extends StatelessWidget {
  final ViewerFooterAction action;
  final TextStyle textStyle;
  const _FooterButton({required this.action, required this.textStyle});

  @override
  Widget build(BuildContext context) {
    final color = action.onTap == null
        ? Colors.white38
        : action.danger
            ? AppColors.danger
            : action.accent
                ? AppColors.accent
                : Colors.white;
    return Tooltip(
      message: action.label,
      child: Semantics(
        button: true,
        enabled: action.onTap != null,
        child: InkWell(
          onTap: action.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(action.icon, size: 24, color: color),
                const SizedBox(height: 4),
                Text(action.label,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    style: textStyle.copyWith(color: color)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
