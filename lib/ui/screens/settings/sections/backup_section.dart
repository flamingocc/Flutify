import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/flutify_tokens.dart';
import '../../../../l10n/l10n.dart';
import '../../../../models/app_preferences.dart';
import '../../../../models/playlist.dart';
import '../../../../providers/preferences_provider.dart';
import '../../../../services/backup/playlist_backup_service.dart';
import '../../../navigation/app_routes.dart';
import '../../../widgets/cover_image.dart';
import '../../../widgets/toast/app_toast.dart';
import '../../auth/backup_account_login_screen.dart';
import '../widgets/settings_section.dart';

/// 设置页「歌单备份」分组：
/// - 开关打开后允许：
///   1) 自动备份本机已登录账号（本机收藏更改立即落盘）；
///   2) 独立 WebView 资料登录 `open.spotify.com` 添加多个要同步歌单的账号；
///   3) 一键同步已备份的歌单与已收藏歌曲到本账号；
///   4) 设置备份频率（最短 20min，提供 20min / 1h / 2h / 12h / 1d 防限流）；
///   5) 列表样式浏览已落盘的备份歌单（点击直接进原生歌单详情页，不做云端预览）。
class BackupSection extends StatelessWidget {
  const BackupSection({super.key, this.loginExternalAccount});

  /// 可选注入外部账号登录回调（测试用；默认打开独立 WebView 登录页 [BackupAccountLoginScreen]）。
  final Future<BackupLoginResult?> Function(BuildContext context)?
      loginExternalAccount;

  static String _intervalLabel(int minutes) => switch (minutes) {
    20 => '20 分钟',
    60 => '1 小时',
    120 => '2 小时',
    720 => '12 小时',
    1440 => '1 天',
    _ => '$minutes 分钟',
  };

  Future<void> _addAccount(
    BuildContext context,
    PlaylistBackupService service,
  ) async {
    final login = loginExternalAccount ?? BackupAccountLoginScreen.open;
    final result = await login(context);
    if (result == null ||
        (result.spDc.isEmpty && result.accessToken.isEmpty) ||
        !context.mounted) {
      return;
    }
    try {
      final account = await service.addAccountWithSpDc(
        result.spDc,
        accessToken: result.accessToken,
        clientToken: result.clientToken,
        userId: result.userId,
        email: result.email,
        displayName: result.displayName,
        avatarUrl: result.avatarUrl,
        profileDir: result.profileDir,
      );
      if (!context.mounted) return;
      AppToast.show(
        context,
        '已备份账号「${account.title}」（${account.likedTracks.length} 首已收藏歌曲，${account.playlists.length} 个歌单）',
        icon: Icons.check_circle_rounded,
        tone: ToastTone.success,
      );
    } catch (e) {
      if (!context.mounted) return;
      AppToast.show(
        context,
        '添加备份账号失败：$e',
        icon: Icons.error_outline_rounded,
        tone: ToastTone.error,
      );
    }
  }

  Future<void> _syncToCurrentAccount(
    BuildContext context,
    PlaylistBackupService service,
  ) async {
    final result = await service.syncToCurrentAccount();
    if (!context.mounted) return;
    AppToast.show(
      context,
      '已同步 ${result.syncedPlaylists} 个备份歌单、${result.addedLikedTracks} 首收藏歌曲到本账号',
      icon: Icons.sync_rounded,
      tone: ToastTone.success,
    );
  }

  Future<void> _backupNow(
    BuildContext context,
    PlaylistBackupService service,
  ) async {
    await service.backupAllAccounts();
    if (!context.mounted) return;
    final err = service.lastError;
    if (err != null) {
      AppToast.show(
        context,
        err,
        icon: Icons.warning_amber_rounded,
        tone: ToastTone.warning,
      );
    } else {
      AppToast.show(
        context,
        '已将全部备份账号的收藏歌单写入本地磁盘',
        icon: Icons.save_alt_rounded,
        tone: ToastTone.success,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefsProvider = context.watch<PreferencesProvider>();
    final backupService = context.watch<PlaylistBackupService?>();
    final prefs = prefsProvider.prefs;
    final enabled = prefs.backupEnabled;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    void updatePrefs({
      bool? backupEnabled,
      bool? autoCurrent,
      int? intervalMinutes,
    }) {
      final next = prefs.copyWith(
        backupEnabled: backupEnabled,
        backupAutoCurrentAccount: autoCurrent,
        backupIntervalMinutes: intervalMinutes,
      );
      prefsProvider.update(next);
      backupService?.configure(
        enabled: next.backupEnabled,
        autoCurrentAccount: next.backupAutoCurrentAccount,
        intervalMinutes: next.backupIntervalMinutes,
      );
    }

    final accounts = backupService?.accounts ?? const <BackupAccount>[];
    final playlists =
        backupService?.allBackedUpPlaylists ?? const <SpotifyPlaylist>[];
    final backingUp = backupService?.isBackingUp ?? false;

    return SettingsSection(
      title: '歌单备份',
      footer: '备份的已收藏歌曲与歌单直接落盘保存，点击查看时直接读取本地数据，不做云端预览以防封禁。',
      children: [
        SettingsSwitchTile(
          title: '启用歌单备份',
          subtitle: '支持本机账号自动备份与独立 WebView 多账号收藏歌单备份落盘',
          value: enabled,
          onChanged: (value) => updatePrefs(backupEnabled: value),
        ),
        if (enabled) ...[
          SettingsSwitchTile(
            title: '自动备份本机已登录的账号',
            subtitle: '本机账号的收藏更改立即落盘，不等定时轮询',
            value: prefs.backupAutoCurrentAccount,
            onChanged: (value) => updatePrefs(autoCurrent: value),
          ),
          SettingsTile(
            title: '自动备份频率',
            subtitle: '最短 20 分钟以防止触发服务端限流',
            trailing: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: AppPreferences.backupIntervalOptions.contains(
                  prefs.backupIntervalMinutes,
                )
                    ? prefs.backupIntervalMinutes
                    : AppPreferences.defaultBackupIntervalMinutes,
                items: [
                  for (final minutes in AppPreferences.backupIntervalOptions)
                    DropdownMenuItem<int>(
                      value: minutes,
                      child: Text(_intervalLabel(minutes)),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) updatePrefs(intervalMinutes: value);
                },
              ),
            ),
          ),
          if (backupService != null) ...[
            SettingsTile(
              title: '添加要同步歌单的账号',
              subtitle: '使用独立 WebView 资料登录 open.spotify.com 并读取其已收藏歌曲的歌单',
              trailing: backingUp
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.person_add_alt_1_rounded),
              onTap: backingUp
                  ? null
                  : () => _addAccount(context, backupService),
            ),
            SettingsTile(
              title: '一键同步已备份的歌单到本账号',
              subtitle: '将下方已勾选账号的收藏歌曲与歌单合并到当前登录账号',
              trailing: const Icon(Icons.sync_rounded),
              onTap: accounts.isEmpty || backingUp
                  ? null
                  : () => _syncToCurrentAccount(context, backupService),
            ),
            SettingsTile(
              title: '立即备份全部账号',
              subtitle: '手动拉取各账号最新收藏并写入本地磁盘',
              trailing: const Icon(Icons.backup_rounded),
              onTap: backingUp
                  ? null
                  : () => _backupNow(context, backupService),
            ),
            for (final account in accounts)
              _BackupAccountTile(
                account: account,
                onToggleSync: (v) =>
                    backupService.setAccountSyncEnabled(account.uniqueId, v),
                onRemove: account.isCurrentAccount
                    ? null
                    : () => backupService.removeAccount(account.uniqueId),
              ),
            if (playlists.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  '已落盘的备份歌单（${playlists.length}）',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            for (final playlist in playlists)
              _BackedUpPlaylistTile(playlist: playlist),
          ],
        ],
      ],
    );
  }
}

class _BackupAccountTile extends StatelessWidget {
  final BackupAccount account;
  final ValueChanged<bool> onToggleSync;
  final VoidCallback? onRemove;

  const _BackupAccountTile({
    required this.account,
    required this.onToggleSync,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final badge = account.isCurrentAccount ? '本机账号' : '外部备份账号';
    return SettingsTile(
      title: '${account.title}（$badge）',
      subtitle:
          '已落盘 ${account.likedTracks.length} 首收藏歌曲 · ${account.playlists.length} 个歌单',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: '参与一键同步到本账号',
            child: Switch.adaptive(
              value: account.syncToLocal,
              onChanged: onToggleSync,
            ),
          ),
          if (onRemove != null)
            IconButton(
              icon: Icon(
                Icons.delete_outline_rounded,
                color: colorScheme.error,
              ),
              tooltip: '移除该备份账号',
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }
}

/// 与媒体库列表一致的本地歌单行：点击直接进入 [PlaylistDetailScreen]（复用 `collection_widgets.dart`）。
class _BackedUpPlaylistTile extends StatelessWidget {
  final SpotifyPlaylist playlist;

  const _BackedUpPlaylistTile({required this.playlist});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;
    return InkWell(
      mouseCursor: SystemMouseCursors.click,
      borderRadius: context.tokens.radius(12),
      onTap: () => AppRoutes.openPlaylist(context, playlist),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            CoverImage(
              url: playlist.coverUrl,
              size: 48,
              borderRadius: context.tokens.radius(8),
              placeholderIcon: Icons.queue_music_rounded,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    playlist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    l10n.subtitleJoin(
                      playlist.ownerName,
                      l10n.songCount(playlist.tracks.length),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
