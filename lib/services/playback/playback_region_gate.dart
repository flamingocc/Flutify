import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../auth/login_region_check.dart';

/// 播放 / 加载前的网络出口地区门控。
///
/// 和登录页用同一套检测（[LoginRegionCheck]）：出口在中国大陆时不开始播放，把
/// 「这首歌为什么不出声」变成一句能看懂的提示。检测在无头 WebView 里跑，所以只在
/// 真正要起播时做，且结果按网络环境缓存——见 [markNetworkChanged]。
///
/// 关闭检测（设置项）或用户选了「本次打开跳过」时，[ensureAllowed] 直接放行，一次检测都不发。
class PlaybackRegionGate {
  PlaybackRegionGate({
    LoginRegionProbe? probe,
    bool Function()? enabled,
    bool Function()? recheckOnNetworkChange,
    bool Function()? skipThisRun,
    WebViewEnvironment? environment,
  }) : _probe = probe,
       _enabled = enabled ?? (() => true),
       _recheckOnNetworkChange = recheckOnNetworkChange ?? (() => true),
       _skipThisRun = skipThisRun ?? (() => LoginRegionCheck.skippedThisRun),
       _environment = environment;

  /// 未注入探针时走无头 WebView 读 Cloudflare trace，环境用 [_environment]。
  final LoginRegionProbe? _probe;
  final bool Function() _enabled;
  final bool Function() _recheckOnNetworkChange;
  final bool Function() _skipThisRun;

  /// 网络环境变化且开启了「网络变动时自动复查」时的通知（由播放器订阅以在播中实时复检）。
  VoidCallback? onNetworkChanged;

  /// 与登录页共用的 WebView2 环境（同一用户数据目录只允许一个实例）。
  WebViewEnvironment? _environment;

  /// 环境还没就绪时补上。同一个环境实例只允许创建一次，晚到的注入直接替换空值即可。
  void attachEnvironment(WebViewEnvironment? environment) {
    _environment ??= environment;
  }

  /// 同一次检测只跑一遍：并发起播（预取 / 自动跳过）不该各开一个无头 WebView。
  Future<LoginRegion>? _inFlight;

  /// 已知的出口地区；网络环境变动、开关变化时作废。
  LoginRegion? _known;

  /// 当前已知出口是中国大陆。
  bool get isBlocked => _known?.isMainlandChina ?? false;

  /// 最近一次检测到的两位国家 / 地区代码。
  String? get country => _known?.code;

  /// 网络环境变了（用户换了代理 / 切了网络）：下次 [ensureAllowed] 重新检测。
  /// 只在网络真的变了时调用，不做定时轮询；关闭「网络变动时自动复查」时沿用上次结果。
  void markNetworkChanged() {
    if (!_recheckOnNetworkChange()) return;
    _known = null;
    _inFlight = null;
    onNetworkChanged?.call();
  }

  /// 开关变化时清掉结论：关掉再打开应当重新检测，而不是沿用关闭前的旧结果。
  void reset() {
    _known = null;
    _inFlight = null;
  }

  /// 播放 / 加载前调用：返回 null 表示放行，否则是拒绝原因。
  Future<PlaybackRegionBlock?> ensureAllowed() async {
    if (!_enabled() || _skipThisRun()) return null;
    final known = _known;
    if (known != null) {
      return known.isMainlandChina ? PlaybackRegionBlock(known.code) : null;
    }
    final probe =
        _probe ?? (() => LoginRegionCheck.detect(environment: _environment));
    final result = await (_inFlight ??= probe().whenComplete(() {
      _inFlight = null;
    }));
    _known = result;
    return result.isMainlandChina ? PlaybackRegionBlock(result.code) : null;
  }
}

/// 被地区门控拦下：出口在 [code]（目前只有 `CN` 会走到这里）。
@immutable
class PlaybackRegionBlock {
  const PlaybackRegionBlock(this.code);

  final String? code;
}
