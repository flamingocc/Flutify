import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

/// 流动封面背景的绘制器。配方与 Android 原生背景（AppleMusicBackgroundPlugin.kt）保持一致，
/// 两端看到的是同一种模糊：
///
/// - 在 1/[downscale] 分辨率、屏幕 1.3 倍大的离屏画布上合成：黑底 + 三份封面
///   （边长为画布长边 1.3 倍，周期 -120s / 90s / 70s 各自旋转，后两份有固定偏移），
///   封面饱和度 [saturation]；
/// - 再叠一层固定的压暗/提亮（深色 50% 黑 + 5% 白；浅色 30% 黑 + 10% 白）；
/// - 模糊半径对应 Android RenderScript 的 radius 25（σ≈10.6 个小像素），边缘夹取；
/// - 放大到屏幕 1.3 倍并居中裁切（-15% 偏移），与原生端的绘制方式相同。
///
/// 小分辨率合成 + 双线性放大，像素工作量约为屏幕分辨率下的 1/64。
class LiquidArtworkPainter extends CustomPainter {
  static const double downscale = 8;

  /// RenderScript `ScriptIntrinsicBlur` 的 σ = 0.4 * radius + 0.6，radius 取其上限 25。
  static const double blurSigma = 0.4 * 25 + 0.6;
  static const double saturation = 2.5;

  /// 每份封面的旋转周期（毫秒），负数为逆时针。与原生端一致。
  static const List<double> periodsMs = [-120000, 90000, 70000];

  /// 与原生端相同的灰度权重（Android ColorMatrix.setSaturation）。
  static const List<double> _luma = [0.213, 0.715, 0.072];

  /// 测试可见：统计真正执行离屏模糊光栅化的次数（推进相位帧时不应重复增长）。
  @visibleForTesting
  static int debugRasterizeCount = 0;

  static final List<_BakedArtwork> _cache = [];
  static const int _maxCacheEntries = 2;

  /// 相位 = 已流动的秒数（不取模，由绘制器按各自周期换算角度）。
  final ValueListenable<double> phase;
  final Animation<double> fade;
  final ui.Image? image;

  /// 切歌淡入时垫在下面的上一张封面，按 [previousPhase] 冻结在换歌那一刻。
  final ui.Image? previous;
  final double previousPhase;
  final bool dark;

  LiquidArtworkPainter({
    required this.phase,
    required this.fade,
    required this.image,
    this.previous,
    this.previousPhase = 0,
    this.dark = true,
  }) : super(repaint: Listenable.merge([phase, fade]));

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final previous = this.previous;
    if (previous != null) {
      _paintBackground(canvas, size, previous, previousPhase, 1);
    }
    final image = this.image;
    final alpha = fade.value.clamp(0.0, 1.0);
    if (image == null || alpha <= 0) return;
    _paintBackground(canvas, size, image, phase.value, alpha);
  }

  /// 用缓存好的小分辨率模糊封面按当前相位旋转合成，再按 [alpha] 铺到 [canvas]。
  ///
  /// 二维各向同性高斯模糊对旋转和平移不变：先把「提饱和度 + 高斯模糊」在小分辨率下
  /// 预烘焙成 `ui.Image`（仅在封面或尺寸变化时做一次），每帧只做 3 次矩阵变换贴图，
  /// 省掉每帧的 `PictureRecorder + saveLayer(ImageFilter.blur) + toImageSync`。
  void _paintBackground(
    Canvas canvas,
    Size size,
    ui.Image image,
    double elapsedSeconds,
    double alpha,
  ) {
    // 离屏画布覆盖屏幕的 1.3 倍（逻辑像素），内部按 1/downscale 缩小
    final bufW = size.width * 1.3;
    final bufH = size.height * 1.3;
    final w = math.max(1, (bufW / downscale).round());
    final h = math.max(1, (bufH / downscale).round());
    final smallSide = math.max(1, (math.max(w, h) * 1.3).round());
    final baked = _obtainBaked(image, smallSide);

    final screenRect = Offset.zero & size;
    canvas
      ..save()
      ..clipRect(screenRect);
    if (alpha < 1.0) {
      canvas.saveLayer(
        screenRect,
        Paint()..color = Color.fromRGBO(0, 0, 0, alpha),
      );
    }
    canvas.translate(-size.width * 0.15, -size.height * 0.15);
    _compose(canvas, bufW, bufH, baked, elapsedSeconds);
    if (alpha < 1.0) {
      canvas.restore();
    }
    canvas.restore();
  }

  static _BakedArtwork _obtainBaked(ui.Image image, int smallSide) {
    for (var i = 0; i < _cache.length; i++) {
      final entry = _cache[i];
      if (identical(entry.source, image) && entry.smallSide == smallSide) {
        if (i != 0) {
          _cache
            ..removeAt(i)
            ..insert(0, entry);
        }
        return entry;
      }
    }
    debugRasterizeCount++;
    final created = _BakedArtwork.rasterize(
      image: image,
      smallSide: smallSide,
      blurSigma: blurSigma,
      saturationMatrix: _saturationMatrix(saturation),
    );
    _cache.insert(0, created);
    while (_cache.length > _maxCacheEntries) {
      _cache.removeLast().dispose();
    }
    return created;
  }

  /// 黑底 + 三份旋转的预模糊封面 + 固定压暗层，坐标为 [w]×[h] 的逻辑像素。
  void _compose(
    Canvas canvas,
    double w,
    double h,
    _BakedArtwork baked,
    double elapsedSeconds,
  ) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h),
      Paint()..color = const Color(0xFF000000),
    );
    final side = math.max(w, h) * 1.3;
    final paint = Paint()..filterQuality = FilterQuality.low;
    final clampedSrc = Rect.fromLTWH(
      0,
      0,
      baked.clamped.width.toDouble(),
      baked.clamped.height.toDouble(),
    );
    final clampedDst = Rect.fromLTWH(0, 0, side, side);
    final padInBuf = side * (baked.pad / baked.smallSide);
    final featheredSrc = Rect.fromLTWH(
      0,
      0,
      baked.feathered.width.toDouble(),
      baked.feathered.height.toDouble(),
    );
    final featheredDst = Rect.fromLTWH(
      -padInBuf,
      -padInBuf,
      side + padInBuf * 2,
      side + padInBuf * 2,
    );
    for (var i = 0; i < 3; i++) {
      final angle =
          (elapsedSeconds * 1000 / periodsMs[i]).remainder(1.0) * 2 * math.pi;
      canvas
        ..save()
        ..transform(_layerMatrix(i, angle, w, h, side).storage);
      if (i == 0) {
        canvas.drawImageRect(baked.clamped, clampedSrc, clampedDst, paint);
      } else {
        canvas.drawImageRect(
          baked.feathered,
          featheredSrc,
          featheredDst,
          paint,
        );
      }
      canvas.restore();
    }
    // 压暗 + 轻微提亮（与原生端同序同值）
    canvas
      ..drawRect(
        Rect.fromLTWH(0, 0, w, h),
        Paint()..color = Color(dark ? 0x80000000 : 0x4D000000),
      )
      ..drawRect(
        Rect.fromLTWH(0, 0, w, h),
        Paint()..color = Color(dark ? 0x0DFFFFFF : 0x1AFFFFFF),
      );
  }

  /// 原生端 `Matrix`：绕 side×side 中心旋转 → 居中到画布，
  /// 第 2 份再平移 (-.95w, -.7h)，第 3 份平移 (-.5w, .7h) 后绕画布中心再转一次。
  Matrix4 _layerMatrix(
    int index,
    double angle,
    double w,
    double h,
    double side,
  ) {
    Matrix4 about(double cx, double cy) =>
        Matrix4.translationValues(cx, cy, 0) *
        Matrix4.rotationZ(angle) *
        Matrix4.translationValues(-cx, -cy, 0);

    var m = about(side / 2, side / 2);
    m = Matrix4.translationValues((w - side) / 2, (h - side) / 2, 0) * m;
    if (index == 1) {
      m = Matrix4.translationValues(-0.95 * w, -0.7 * h, 0) * m;
    }
    if (index == 2) {
      m = Matrix4.translationValues(-0.5 * w, 0.7 * h, 0) * m;
      m = about(w / 2, h / 2) * m;
    }
    return m;
  }

  /// Android `ColorMatrix.setSaturation` 的 4x5 矩阵。
  static List<double> _saturationMatrix(double s) {
    final inv = 1 - s;
    final r = _luma[0] * inv, g = _luma[1] * inv, b = _luma[2] * inv;
    return [
      r + s, g, b, 0, 0, //
      r, g + s, b, 0, 0,
      r, g, b + s, 0, 0,
      0, 0, 0, 1, 0,
    ];
  }

  @override
  bool shouldRepaint(LiquidArtworkPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.previous != previous ||
      oldDelegate.previousPhase != previousPhase ||
      oldDelegate.dark != dark ||
      oldDelegate.phase != phase ||
      oldDelegate.fade != fade;
}

class _BakedArtwork {
  final ui.Image source;
  final int smallSide;
  final int pad;
  final ui.Image clamped;
  final ui.Image feathered;

  const _BakedArtwork({
    required this.source,
    required this.smallSide,
    required this.pad,
    required this.clamped,
    required this.feathered,
  });

  factory _BakedArtwork.rasterize({
    required ui.Image image,
    required int smallSide,
    required double blurSigma,
    required List<double> saturationMatrix,
  }) {
    final srcBounds = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final imagePaint = Paint()
      ..filterQuality = FilterQuality.medium
      ..colorFilter = ColorFilter.matrix(saturationMatrix);

    // 底层（第 1 份封面）：铺满整个离屏区域，边缘用 clamp 保持不透明
    final clampedRecorder = ui.PictureRecorder();
    final clampedCanvas = Canvas(clampedRecorder);
    final clampedRect = Rect.fromLTWH(
      0,
      0,
      smallSide.toDouble(),
      smallSide.toDouble(),
    );
    clampedCanvas.saveLayer(
      clampedRect,
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: blurSigma,
          sigmaY: blurSigma,
          tileMode: TileMode.clamp,
        ),
    );
    clampedCanvas.drawImageRect(image, srcBounds, clampedRect, imagePaint);
    clampedCanvas.restore();
    final clampedPic = clampedRecorder.endRecording();
    final clamped = clampedPic.toImageSync(smallSide, smallSide);
    clampedPic.dispose();

    // 叠层（第 2、3 份偏移封面）：四周留出 3σ 透明边距，旋转叠加时边缘自然高斯羽化
    final pad = (blurSigma * 3).ceil();
    final paddedSide = smallSide + pad * 2;
    final featheredRecorder = ui.PictureRecorder();
    final featheredCanvas = Canvas(featheredRecorder);
    final outerRect = Rect.fromLTWH(
      0,
      0,
      paddedSide.toDouble(),
      paddedSide.toDouble(),
    );
    final innerRect = Rect.fromLTWH(
      pad.toDouble(),
      pad.toDouble(),
      smallSide.toDouble(),
      smallSide.toDouble(),
    );
    featheredCanvas.saveLayer(
      outerRect,
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: blurSigma,
          sigmaY: blurSigma,
          tileMode: TileMode.decal,
        ),
    );
    featheredCanvas.drawImageRect(image, srcBounds, innerRect, imagePaint);
    featheredCanvas.restore();
    final featheredPic = featheredRecorder.endRecording();
    final feathered = featheredPic.toImageSync(paddedSide, paddedSide);
    featheredPic.dispose();

    return _BakedArtwork(
      source: image,
      smallSide: smallSide,
      pad: pad,
      clamped: clamped,
      feathered: feathered,
    );
  }

  void dispose() {
    clamped.dispose();
    feathered.dispose();
  }
}
