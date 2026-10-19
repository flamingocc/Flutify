import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../l10n/l10n.dart';

import '../../../../core/theme/flutify_tokens.dart';
import '../../../../services/auth/web_token_service.dart';
import '../../../widgets/toast/app_toast.dart';
import '../../auth/web_login_screen.dart';
import 'package:material_3_expressive/material_3_expressive.dart' show M3EButton;

/// 设置页「全曲播放（Web 登录）」卡片。
///
/// 全曲播放（Widevine DRM）的真密钥只发给 Web 播放器 token，而 Web token 由
/// sp_dc cookie 铸造；本卡片展示 Web 登录态并引导完成一次内嵌 Web 登录来捕获 sp_dc。
/// 与桌面 OAuth（账号卡片）互补：一个管媒体库 / API，一个管全曲解密密钥。
///
/// 文案随应用语言切换。
class WebLoginCard extends StatefulWidget {
  const WebLoginCard({super.key});

  @override
  State<WebLoginCard> createState() => _WebLoginCardState();
}

class _WebLoginCardState extends State<WebLoginCard> {
  static const double _stackActionsBelow = 420;

  bool _busy = false;

  Future<void> _login() async {
    setState(() => _busy = true);
    try {
      // 统一登录页：Web 登录成功后会顺带无感完成桌面 OAuth（若尚未登录）
      final result = await WebLoginScreen.open(context);
      if (!mounted) return;
      if (result?.webSignedIn ?? false) {
        AppToast.show(
          context,
          context.l10n.webLoginSuccess,
          icon: Icons.check_circle_rounded,
          tone: ToastTone.success,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    final tokens = context.read<WebTokenService>();
    await tokens.clear();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final signedIn = context.read<WebTokenService>().hasSpDc;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: context.tokens.radius(20),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stackActions = constraints.maxWidth < _stackActionsBelow;
          final icon = Container(
            // 钥匙图标块：与账号卡片的品牌标位置对应，表意「解密密钥」
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: signedIn
                  ? colorScheme.primaryContainer
                  : colorScheme.surfaceContainerHighest,
              borderRadius: context.tokens.radius(14),
            ),
            child: Icon(
              signedIn ? Icons.key_rounded : Icons.key_off_rounded,
              color: signedIn
                  ? colorScheme.onPrimaryContainer
                  : colorScheme.onSurfaceVariant,
            ),
          );
          final texts = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.webLoginCardTitle,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                signedIn
                    ? context.l10n.webLoginReady
                    : context.l10n.webLoginRequired,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          );
          final clearButton = M3EButton.text(
            onPressed: _busy ? null : _clear,
            child: Text(context.l10n.commonClear),
          );
          final loginButton = M3EButton.tonal(
            onPressed: _busy ? null : _login,
            child: Text(
              signedIn
                  ? context.l10n.authSignInAgain
                  : context.l10n.webLoginAction,
            ),
          );

          if (!stackActions) {
            return Row(
              children: [
                icon,
                const SizedBox(width: 14),
                Expanded(child: texts),
                const SizedBox(width: 12),
                if (signedIn) clearButton,
                const SizedBox(width: 4),
                loginButton,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  icon,
                  const SizedBox(width: 14),
                  Expanded(child: texts),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (signedIn) ...[
                    clearButton,
                    const SizedBox(width: 8),
                  ],
                  loginButton,
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
