import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;

import '../src/rust/frb_generated.dart';

/// Rust 核心（flutify_core）的加载状态。
///
/// 应用启动时若 Rust 核心加载失败则直接退出进程；
/// 纯 Dart 单元测试环境（未调用 [initialize]）保持 [ready] 为 false。
class RustCore {
  RustCore._();

  static bool _ready = false;
  static bool get ready => _ready;

  /// [externalLibrary]：测试里加载本地编译的动态库（rust/flutify_core/target/release），
  /// 用来核对 Rust 与纯 Dart 实现逐字节一致。
  static Future<void> initialize({
    bool exitOnFailure = true,
    ExternalLibrary? externalLibrary,
  }) async {
    if (_ready) return;
    try {
      await RustLib.init(externalLibrary: externalLibrary);
      _ready = true;
    } catch (e, st) {
      debugPrint('Rust 核心加载失败：$e\n$st');
      if (exitOnFailure) {
        exit(1);
      }
    }
  }
}
