import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../l10n/l10n.dart';
import '../../../services/auth/login_region_check.dart';
import '../../../services/auth/web_login_flow.dart';
import '../../../services/auth/web_token_service.dart';

/// 独立 WebView 资料登录页的结果：返回该备份账号专属的 [spDc] 与独立资料目录 [profileDir]。
class BackupLoginResult {
  final String spDc;
  final String profileDir;

  const BackupLoginResult({required this.spDc, required this.profileDir});
}

/// 独立 WebView 资料登录页（供歌单备份添加额外账号使用）：
///
/// - 每个备份账号使用独立的 `userDataFolder`（Windows `WebViewEnvironment`）或独立无痕存储，
///   与主账号的 `EmePlayer.cachedEnvironment` 完全隔离，互不串号；
/// - 登录 `open.spotify.com` 后通过该环境的 `CookieManager` 捕获 `sp_dc`，并铸造一次
///   Web token 校验有效性，随后立即销毁 WebView 并把凭据交回备份服务拉取收藏落盘。
class BackupAccountLoginScreen extends StatefulWidget {
  const BackupAccountLoginScreen({super.key, this.regionProbe});

  final LoginRegionProbe? regionProbe;

  static Future<BackupLoginResult?> open(BuildContext context) {
    return Navigator.of(context, rootNavigator: true).push<BackupLoginResult?>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const BackupAccountLoginScreen(),
      ),
    );
  }

  @override
  State<BackupAccountLoginScreen> createState() =>
      _BackupAccountLoginScreenState();
}

class _BackupAccountLoginScreenState extends State<BackupAccountLoginScreen> {
  static const String _loginUrl =
      'https://accounts.spotify.com/zh-CN/login?continue=https%3A%2F%2Fopen.spotify.com%2F';

  WebViewEnvironment? _environment;
  late final String _profileDir;
  late final WebLoginFlow _flow;
  Timer? _pollTimer;
  String? _capturedSpDc;
  bool _envReady = false;
  bool _regionChecking = false;
  bool _regionBlocked = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _profileDir =
        '${Directory.systemTemp.path}${Platform.pathSeparator}flutify_backup_profile_${DateTime.now().millisecondsSinceEpoch}';
    _flow = WebLoginFlow(
      readSpDc: _readSpDc,
      saveSpDc: (spDc) async => _capturedSpDc = spDc,
      prepareWebToken: () async {
        final dc = _capturedSpDc;
        if (dc != null && dc.isNotEmpty) {
          await WebTokenService.mintTokenForSpDc(dc);
        }
      },
      desktopSignedIn: () => true,
      beginDesktopOAuth: () async => null,
      onFinished: (_) {
        final dc = _flow.spDc ?? _capturedSpDc;
        if (dc != null && dc.isNotEmpty) {
          _finish(BackupLoginResult(spDc: dc, profileDir: _profileDir));
        }
      },
    );
    _flow.addListener(_onFlowChanged);
    _pollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _flow.poll(),
    );
    unawaited(_initIsolatedEnvironment());
  }

  Future<void> _initIsolatedEnvironment() async {
    if (!LoginRegionCheck.skippedThisRun) {
      setState(() => _regionChecking = true);
      final probe =
          widget.regionProbe ?? () => LoginRegionCheck.detect(environment: _environment);
      LoginRegion region;
      try {
        region = await probe();
      } catch (_) {
        region = const LoginRegion.unknown();
      }
      if (!mounted || _done) return;
      if (region.isMainlandChina) {
        setState(() {
          _regionChecking = false;
          _regionBlocked = true;
        });
        return;
      }
      setState(() => _regionChecking = false);
    }

    if (Platform.isWindows) {
      try {
        final dir = Directory(_profileDir);
        if (!dir.existsSync()) dir.createSync(recursive: true);
        _environment = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(userDataFolder: _profileDir),
        );
      } catch (_) {}
    }
    if (!mounted || _done) return;
    setState(() {
      _regionBlocked = false;
      _envReady = true;
    });
  }

  void _skipRegionAndContinue() {
    LoginRegionCheck.skipForThisRun();
    setState(() => _regionBlocked = false);
    unawaited(_initIsolatedEnvironment());
  }

  Future<String?> _readSpDc() async {
    if (!_envReady || !mounted || _done) return null;
    final manager = CookieManager.instance(webViewEnvironment: _environment);
    for (final url in const [
      'https://open.spotify.com',
      'https://accounts.spotify.com',
      'https://www.spotify.com',
    ]) {
      try {
        final c = await manager.getCookie(url: WebUri(url), name: 'sp_dc');
        final v = c?.value.trim();
        if (v != null && v.isNotEmpty) return v;
      } catch (_) {}
    }
    return null;
  }

  void _onFlowChanged() {
    if (mounted && !_done) setState(() {});
  }

  void _finish(BackupLoginResult? result) {
    if (_done || !mounted) return;
    _done = true;
    Navigator.of(context, rootNavigator: true).pop(result);
  }

  @override
  void dispose() {
    _done = true;
    _pollTimer?.cancel();
    _flow.removeListener(_onFlowChanged);
    _flow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: const Text('登录要备份的 Spotify 账号'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => _finish(null),
        ),
      ),
      body: _regionChecking
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(l10n.webLoginRegionChecking),
                ],
              ),
            )
          : _regionBlocked
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.public_off_rounded, size: 48),
                    const SizedBox(height: 16),
                    Text(
                      l10n.webLoginRegionBlockedTitle,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.webLoginRegionBlockedBody,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _skipRegionAndContinue,
                      child: Text(l10n.regionCheckSkipThisRun),
                    ),
                  ],
                ),
              ),
            )
          : !_envReady
          ? const Center(child: CircularProgressIndicator())
          : InAppWebView(
              webViewEnvironment: _environment,
              initialUrlRequest: URLRequest(url: WebUri(_loginUrl)),
              initialSettings: InAppWebViewSettings(
                incognito: !Platform.isWindows,
                javaScriptEnabled: true,
              ),
              onLoadStop: (_, _) => _flow.poll(),
            ),
    );
  }
}
