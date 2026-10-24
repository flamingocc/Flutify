import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart'
    show M3ELoadingIndicator, M3EProgressIndicator;

/// 行内加载圈：MD3E 圆形进度（不定进度时无轨道，与原生观感一致）。
///
/// 尺寸跟随外层约束（常见用法是放进 `SizedBox.square`），无界时退回 [fallbackSize]。
class FlutifySpinner extends StatelessWidget {
  final double strokeWidth;
  final Color? color;
  final double? value;
  final String? semanticsLabel;
  final double fallbackSize;

  const FlutifySpinner({
    super.key,
    this.strokeWidth = 2,
    this.color,
    this.value,
    this.semanticsLabel,
    this.fallbackSize = 20,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticsLabel,
      value: value == null ? null : '${(value! * 100).round()}%',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final bounded =
              constraints.hasBoundedWidth && constraints.hasBoundedHeight;
          final size = bounded
              ? (constraints.maxWidth < constraints.maxHeight
                    ? constraints.maxWidth
                    : constraints.maxHeight)
              : fallbackSize;
          return Center(
            child: M3EProgressIndicator.circular(
              value: value,
              size: size,
              strokeWidth: strokeWidth,
              trackStrokeWidth: strokeWidth,
              color: color ?? Theme.of(context).colorScheme.primary,
              trackColor: value == null ? Colors.transparent : null,
            ),
          );
        },
      ),
    );
  }
}

/// 整页 / 大块区域等待：MD3E Expressive 变形加载指示器。
class FlutifyLoadingIndicator extends StatelessWidget {
  final String? semanticsLabel;

  const FlutifyLoadingIndicator({super.key, this.semanticsLabel});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticsLabel,
      child: M3ELoadingIndicator(
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

/// 线性进度条：MD3E 样式（确定进度带间隔与终点圆点），[value] 为 null 时为不定进度。
class FlutifyLinearProgress extends StatelessWidget {
  final double? value;
  final double? thickness;
  final Color? color;
  final Color? trackColor;

  const FlutifyLinearProgress({
    super.key,
    this.value,
    this.thickness,
    this.color,
    this.trackColor,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      value: value == null ? null : '${(value!.clamp(0.0, 1.0) * 100).round()}%',
      child: M3EProgressIndicator.linear(
        value: value?.clamp(0.0, 1.0),
        strokeWidth: thickness,
        trackStrokeWidth: thickness,
        color: color ?? colorScheme.primary,
        trackColor: trackColor ?? colorScheme.surfaceContainerHighest,
      ),
    );
  }
}
