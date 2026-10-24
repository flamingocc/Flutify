import 'dart:io';

import 'package:flutter/foundation.dart';

import '../src/rust/frb_generated.dart';

/// Rust 核心（flutify_core）的加载状态。
///
/// 应用启动时若 Rust 核心加载失败则直接退出进程；
/// 纯 Dart 单元测试环境（未调用 [initialize]）保持 [ready] 为 false。
class RustCore {
  RustCore._();

  static bool _ready = false;
  static bool get ready => _ready;

  static Future<void> initialize({bool exitOnFailure = true}) async {
    if (_ready) return;
    try {
      await RustLib.init();
      _ready = true;
    } catch (e, st) {
      debugPrint('Rust 核心加载失败：$e\n$st');
      if (exitOnFailure) {
        exit(1);
      }
    }
  }
}
