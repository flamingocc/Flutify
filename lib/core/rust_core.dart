import 'package:flutter/foundation.dart';

import '../src/rust/frb_generated.dart';

/// Rust 核心（flutify_core）的加载状态。
///
/// 加载失败（缺少原生库、平台不支持、测试环境等）时 [ready] 保持 false，
/// 调用方应回退到各自的 Dart 实现。
class RustCore {
  RustCore._();

  static bool _ready = false;
  static bool get ready => _ready;

  static Future<void> initialize() async {
    if (_ready) return;
    try {
      await RustLib.init();
      _ready = true;
    } catch (e, st) {
      debugPrint('Rust 核心不可用，使用 Dart 实现：$e\n$st');
    }
  }
}
