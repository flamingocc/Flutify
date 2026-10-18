import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/constants/spotify_endpoints.dart';
import '../../l10n/app_locale.dart';
import '../../models/app_preferences.dart';
import '../../models/image.dart';
import '../../models/playlist.dart';
import '../../models/track.dart';
import '../../providers/library_provider.dart';
import '../../providers/preferences_provider.dart';
import '../auth/client_profile.dart';
import '../library/desktop_library_source.dart';
import '../pathfinder/desktop_data_source.dart';
import '../protocol/access_point.dart';
import '../storage_service.dart';

/// 从独立 WebView 会话拿到的账号凭据与收藏快照。
class BackupAccountSnapshot {
  /// Spotify 唯一用户名 ID（canonical username）。
  final String id;

  /// 账户唯一邮箱（若接口返回则优先作为唯一识别符展示）。
  final String email;

  /// 账号昵称（可能与其他账号重名，仅作辅助展示，不作主键）。
  final String displayName;
  final String avatarUrl;
  final List<SpotifyTrack> likedTracks;
  final List<SpotifyPlaylist> playlists;

  const BackupAccountSnapshot({
    required this.id,
    required this.displayName,
    this.email = '',
    this.avatarUrl = '',
    this.likedTracks = const [],
    this.playlists = const [],
  });

  /// 账户唯一识别符：优先使用邮箱，无邮箱时使用 Spotify 唯一用户名 ID。
  String get uniqueId {
    final mail = email.trim();
    if (mail.isNotEmpty) return mail;
    return id.trim();
  }
}

/// 独立 WebView 登录捕获到的会话信息（直接使用 WebView 内的页面会话，不手动铸造 token）。
class BackupSessionCredentials {
  final String spDc;
  final String accessToken;
  final String clientToken;
  final String userId;
  final String email;
  final String displayName;
  final String avatarUrl;
  final String profileDir;

  const BackupSessionCredentials({
    required this.spDc,
    this.accessToken = '',
    this.clientToken = '',
    this.userId = '',
    this.email = '',
    this.displayName = '',
    this.avatarUrl = '',
    this.profileDir = '',
  });
}

typedef BackupRemoteFetcher =
    Future<BackupAccountSnapshot> Function(String spDc);

/// 单个已备份账号的落盘快照（含「已收藏的歌曲」与收藏歌单的完整曲目，不做云端预览）。
///
/// 主键与展示均采用账户唯一识别符（[uniqueId]：优先邮箱 [email]，其次 Spotify 唯一用户名 [id]），
/// 即使多个账号昵称（[displayName]）完全相同也不会冲突或覆盖。
@immutable
class BackupAccount {
  static const String localAccountFallbackId = 'local_current_account';

  /// Spotify 唯一用户名 ID（canonical username）。
  final String id;

  /// 账户唯一邮箱（如 `user@example.com`）。
  final String email;

  /// 账户昵称（可重复，不作唯一键）。
  final String displayName;
  final String avatarUrl;

  /// 独立 WebView 登录捕获的 `sp_dc`（本机当前账号为空，直接读 [LibraryProvider]）。
  final String spDc;

  /// 独立 WebView 页面自身的会话 `accessToken`（不手动铸造 token）。
  final String accessToken;

  /// 独立 WebView 页面自身的 `client-token`。
  final String clientToken;

  /// 独立 WebView 资料目录名（多账号隔离 Cookie / Storage）。
  final String profileDir;

  /// 是否为本机当前已登录的账号。
  final bool isCurrentAccount;

  /// 一键同步到本账号时是否包含该账号的备份歌单与收藏歌曲。
  final bool syncToLocal;

  final DateTime? lastBackupAt;
  final List<SpotifyTrack> likedTracks;
  final List<SpotifyPlaylist> playlists;

  const BackupAccount({
    required this.id,
    required this.displayName,
    this.email = '',
    this.avatarUrl = '',
    this.spDc = '',
    this.accessToken = '',
    this.clientToken = '',
    this.profileDir = '',
    this.isCurrentAccount = false,
    this.syncToLocal = true,
    this.lastBackupAt,
    this.likedTracks = const [],
    this.playlists = const [],
  });

  /// 账户唯一识别符：优先使用邮箱 [email]，无邮箱时使用 Spotify 唯一用户名 [id]。
  String get uniqueId {
    final mail = email.trim();
    if (mail.isNotEmpty) return mail;
    return id.trim();
  }

  /// 展示标题：以唯一识别符为主（若昵称与唯一识别符不同，则显示「唯一识别符（昵称）」），
  /// 确保同名账号在界面与同步歌单中绝不混淆。
  String get title {
    final uid = uniqueId;
    final name = displayName.trim();
    if (uid.isNotEmpty && name.isNotEmpty && name != uid) {
      return '$uid（$name）';
    }
    return uid.isNotEmpty ? uid : name;
  }

  /// 该账号已备份的「已收藏的歌曲」，以唯一识别符命名与寻址，防止同名账号互相覆盖。
  SpotifyPlaylist get likedSongsPlaylist => SpotifyPlaylist(
    id: 'backup_${uniqueId}_liked',
    name: '$uniqueId · 已收藏的歌曲',
    uri: 'spotify:playlist:backup_${uniqueId}_liked',
    ownerName: title,
    images: const [
      SpotifyImage(url: 'https://misc.scdn.co/liked-songs/liked-songs-640.png'),
    ],
    tracks: likedTracks,
    totalTracks: likedTracks.length,
    primaryColor: '#450af5',
  );

  /// 该账号所有已落盘的备份歌单（含「已收藏的歌曲」与各收藏歌单，均带唯一识别符后缀防撞名）。
  List<SpotifyPlaylist> get backedUpPlaylists => [
    if (likedTracks.isNotEmpty) likedSongsPlaylist,
    for (final p in playlists)
      p.copyWith(
        id: p.id.startsWith('backup_') ? p.id : 'backup_${uniqueId}_${p.id}',
        ownerName: title,
        totalTracks: p.tracks.length,
      ),
  ];

  /// 判断两个账号记录是否属于同一个 Spotify 账户（按唯一 ID 或唯一邮箱比对，绝不按昵称比对）。
  bool matchesIdentity({required String otherId, required String otherEmail}) {
    final aId = id.trim();
    final bId = otherId.trim();
    if (aId.isNotEmpty && bId.isNotEmpty && aId == bId) return true;
    final aMail = email.trim().toLowerCase();
    final bMail = otherEmail.trim().toLowerCase();
    if (aMail.isNotEmpty && bMail.isNotEmpty && aMail == bMail) return true;
    return false;
  }

  BackupAccount copyWith({
    String? id,
    String? email,
    String? displayName,
    String? avatarUrl,
    String? spDc,
    String? accessToken,
    String? clientToken,
    String? profileDir,
    bool? isCurrentAccount,
    bool? syncToLocal,
    DateTime? lastBackupAt,
    List<SpotifyTrack>? likedTracks,
    List<SpotifyPlaylist>? playlists,
  }) {
    return BackupAccount(
      id: id ?? this.id,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      spDc: spDc ?? this.spDc,
      accessToken: accessToken ?? this.accessToken,
      clientToken: clientToken ?? this.clientToken,
      profileDir: profileDir ?? this.profileDir,
      isCurrentAccount: isCurrentAccount ?? this.isCurrentAccount,
      syncToLocal: syncToLocal ?? this.syncToLocal,
      lastBackupAt: lastBackupAt ?? this.lastBackupAt,
      likedTracks: likedTracks ?? this.likedTracks,
      playlists: playlists ?? this.playlists,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'email': email,
    'displayName': displayName,
    'avatarUrl': avatarUrl,
    'spDc': spDc,
    'accessToken': accessToken,
    'clientToken': clientToken,
    'profileDir': profileDir,
    'isCurrentAccount': isCurrentAccount,
    'syncToLocal': syncToLocal,
    'lastBackupAt': lastBackupAt?.toIso8601String(),
    'likedTracks': [for (final t in likedTracks) t.toJson()],
    'playlists': [for (final p in playlists) p.toJson()],
  };

  factory BackupAccount.fromJson(Map<String, dynamic> json) {
    final rawLiked = json['likedTracks'];
    final rawPlaylists = json['playlists'];
    final lastBackupRaw = json['lastBackupAt'];
    return BackupAccount(
      id: json['id'] as String? ?? '',
      email: json['email'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      avatarUrl: json['avatarUrl'] as String? ?? '',
      spDc: json['spDc'] as String? ?? '',
      accessToken: json['accessToken'] as String? ?? '',
      clientToken: json['clientToken'] as String? ?? '',
      profileDir: json['profileDir'] as String? ?? '',
      isCurrentAccount: json['isCurrentAccount'] as bool? ?? false,
      syncToLocal: json['syncToLocal'] as bool? ?? true,
      lastBackupAt: lastBackupRaw is String
          ? DateTime.tryParse(lastBackupRaw)
          : null,
      likedTracks: rawLiked is List
          ? rawLiked
                .whereType<Map<String, dynamic>>()
                .map(SpotifyTrack.fromJson)
                .toList()
          : const [],
      playlists: rawPlaylists is List
          ? rawPlaylists
                .whereType<Map<String, dynamic>>()
                .map(SpotifyPlaylist.fromJson)
                .toList()
          : const [],
    );
  }
}

/// 一键同步备份到当前账号的结果统计。
@immutable
class BackupSyncResult {
  final int addedLikedTracks;
  final int syncedPlaylists;

  const BackupSyncResult({
    required this.addedLikedTracks,
    required this.syncedPlaylists,
  });
}

/// 使用独立 WebView 会话自带的 `accessToken` / `clientToken` 读取账户唯一识别符（邮箱 / 用户名 ID）
/// 及已收藏歌曲和歌单，不手动铸造 token。
class SpDcBackupFetcher {
  static const int _pageSize = 50;
  static const int _maxPages = 6;
  static const int _maxPlaylistsWithTracks = 30;

  final http.Client _client;
  final String _baseUrl;

  SpDcBackupFetcher({
    http.Client? client,
    String baseUrl = SpotifyEndpoints.defaultWebApiBase,
  }) : _client = client ?? http.Client(),
       _baseUrl = baseUrl;

  Future<BackupAccountSnapshot> fetchWithSession(
    BackupSessionCredentials session,
  ) async {
    final token = session.accessToken.trim();
    final clientToken = session.clientToken.trim();
    var id = session.userId.trim();
    var email = session.email.trim();
    var displayName = session.displayName.trim();
    var avatarUrl = session.avatarUrl.trim();

    final headers = <String, String>{
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      if (clientToken.isNotEmpty) 'client-token': clientToken,
      'Accept': 'application/json',
      'Accept-Language': AppLocale.spotifyLanguage,
      'User-Agent': SpotifyClientProfile.desktop.userAgent,
      ...SpotifyClientProfile.desktop.headers,
    };

    // 1. 读取唯一识别符（邮箱 email + 唯一用户名 id）：优先 /v1/me，若被限流则走 APWelcome 取 canonicalUsername
    if (token.isNotEmpty && (id.isEmpty || email.isEmpty)) {
      try {
        final me = await _getJson('$_baseUrl/me', headers);
        final meId = (me['id'] as String? ?? '').trim();
        final meEmail = (me['email'] as String? ?? '').trim();
        final meName = (me['display_name'] as String? ?? '').trim();
        if (meId.isNotEmpty) id = meId;
        if (meEmail.isNotEmpty) email = meEmail;
        if (meName.isNotEmpty && displayName.isEmpty) displayName = meName;
        final images = me['images'];
        if (avatarUrl.isEmpty &&
            images is List &&
            images.isNotEmpty &&
            images.first is Map<String, dynamic>) {
          avatarUrl =
              (images.first as Map<String, dynamic>)['url'] as String? ?? '';
        }
      } catch (_) {}
    }

    if (id.isEmpty && token.isNotEmpty) {
      try {
        final ap = await SpotifyAccessPoint.connect(client: _client);
        try {
          final welcome = await ap.authenticate(
            ApCredentials.accessToken(token),
          );
          if (welcome.canonicalUsername.isNotEmpty) {
            id = welcome.canonicalUsername;
          }
        } finally {
          ap.close();
        }
      } catch (_) {}
    }

    if (id.isEmpty && email.isNotEmpty) {
      id = email;
    }
    if (id.isEmpty) {
      throw StateError('无法读取备份账号的唯一识别符，请确认已在 WebView 中完成登录');
    }
    if (displayName.isEmpty) {
      displayName = email.isNotEmpty ? email : id;
    }

    // 2. 读取已收藏歌曲与歌单：优先走不受公开 API 429 限流的内部接口（spclient + Pathfinder），
    //    失败时回退到公开 Web API（/me/tracks 与 /me/playlists）。
    List<SpotifyTrack> likedTracks = const [];
    List<SpotifyPlaylist> playlists = const [];

    if (token.isNotEmpty) {
      final desktopData = DesktopDataSource(
        _client,
        headers: () async => headers,
        language: () => AppLocale.spotifyLanguage,
      );
      final desktopLib = DesktopLibrarySource(
        client: _client,
        headers: () async => headers,
        data: desktopData,
        username: () => id,
        signedIn: () => true,
      );
      try {
        likedTracks = await desktopLib.fetchLikedTracks();
      } catch (_) {
        likedTracks = await _fetchWebApiLikedTracks(headers);
      }
      try {
        final rawPlaylists = await desktopLib.fetchPlaylists();
        final fullPlaylists = <SpotifyPlaylist>[];
        for (final p in rawPlaylists.take(_maxPlaylistsWithTracks)) {
          if (p.tracks.isNotEmpty) {
            fullPlaylists.add(p);
            continue;
          }
          try {
            final detail = await desktopData.playlist(p.id);
            if (detail != null && detail.tracks.isNotEmpty) {
              fullPlaylists.add(
                p.copyWith(
                  tracks: detail.tracks,
                  totalTracks: detail.tracks.length,
                ),
              );
              continue;
            }
          } catch (_) {}
          fullPlaylists.add(p);
        }
        playlists = fullPlaylists;
      } catch (_) {
        playlists = await _fetchWebApiPlaylists(headers);
      }
    }

    return BackupAccountSnapshot(
      id: id,
      email: email,
      displayName: displayName,
      avatarUrl: avatarUrl,
      likedTracks: likedTracks,
      playlists: playlists,
    );
  }

  Future<BackupAccountSnapshot> fetch(String spDc) =>
      fetchWithSession(BackupSessionCredentials(spDc: spDc));

  Future<List<SpotifyTrack>> _fetchWebApiLikedTracks(
    Map<String, String> headers,
  ) async {
    try {
      final likedItems = await _pages(
        '$_baseUrl/me/tracks?limit=$_pageSize',
        headers,
        (json) => json['items'],
      );
      return [
        for (final item in likedItems)
          if (item is Map<String, dynamic> &&
              item['track'] is Map<String, dynamic>)
            SpotifyTrack.fromJson(
              item['track'] as Map<String, dynamic>,
            ).copyWith(addedAt: SpotifyTrack.parseAddedAt(item['added_at'])),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<List<SpotifyPlaylist>> _fetchWebApiPlaylists(
    Map<String, String> headers,
  ) async {
    try {
      final rawPlaylists = await _pages(
        '$_baseUrl/me/playlists?limit=$_pageSize',
        headers,
        (json) => json['items'],
      );
      final playlists = <SpotifyPlaylist>[];
      for (final item in rawPlaylists.take(_maxPlaylistsWithTracks)) {
        if (item is! Map<String, dynamic>) continue;
        var playlist = SpotifyPlaylist.fromJson(item);
        if (playlist.id.isEmpty) continue;
        if (playlist.tracks.isEmpty) {
          try {
            final trackItems = await _pages(
              '$_baseUrl/playlists/${Uri.encodeComponent(playlist.id)}/tracks?limit=100',
              headers,
              (json) => json['items'],
              maxPages: 3,
            );
            final tracks = <SpotifyTrack>[
              for (final t in trackItems)
                if (t is Map<String, dynamic> &&
                    t['track'] is Map<String, dynamic>)
                  SpotifyTrack.fromJson(
                    t['track'] as Map<String, dynamic>,
                  ).copyWith(addedAt: SpotifyTrack.parseAddedAt(t['added_at'])),
            ];
            playlist = playlist.copyWith(
              tracks: tracks,
              totalTracks: tracks.length,
            );
          } catch (_) {}
        }
        playlists.add(playlist);
      }
      return playlists;
    } catch (_) {
      return const [];
    }
  }

  Future<List<Object?>> _pages(
    String firstUrl,
    Map<String, String> headers,
    Object? Function(Map<String, dynamic> json) itemsOf, {
    int maxPages = _maxPages,
  }) async {
    final result = <Object?>[];
    String? url = firstUrl;
    for (var page = 0; url != null && page < maxPages; page++) {
      final json = await _getJson(url, headers);
      final items = itemsOf(json);
      if (items is List) result.addAll(items);
      url = json['next'] as String?;
    }
    return result;
  }

  Future<Map<String, dynamic>> _getJson(
    String url,
    Map<String, String> headers,
  ) async {
    final res = await _client
        .get(Uri.parse(url), headers: headers)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw HttpException('备份请求失败（HTTP ${res.statusCode}）', uri: Uri.parse(url));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('备份响应格式异常');
    }
    return decoded;
  }
}

/// 歌单备份服务：
/// - 独立 WebView 登录多账号（直接使用 WebView 会话，不手动铸造 token）并按唯一识别符（邮箱 / 用户名 ID）落盘；
/// - 自动备份本机已登录账号，且**本机收藏更改立即落盘**（不等轮询）；
/// - 定时轮询间隔用户可设，强制最短 20 分钟（防限流 / 防封禁）；
/// - 一键将所有启用同步的备份歌单与收藏歌曲同步到当前本机账号。
class PlaylistBackupService extends ChangeNotifier {
  static const int minIntervalMinutes = AppPreferences.minBackupIntervalMinutes;
  static const int defaultIntervalMinutes =
      AppPreferences.defaultBackupIntervalMinutes;
  static const List<int> intervalOptionsMinutes =
      AppPreferences.backupIntervalOptions;

  final StorageService _storage;
  final LibraryProvider? _library;
  final PreferencesProvider? _preferences;
  final BackupRemoteFetcher? _customRemoteFetcher;
  final SpDcBackupFetcher _sessionFetcher;
  final File? _diskFile;
  final DateTime Function() _now;
  final bool _enablePeriodicTimer;

  List<BackupAccount> _accounts = const [];
  bool _enabled = false;
  bool _autoCurrentAccount = true;
  int _intervalMinutes = defaultIntervalMinutes;
  bool _isBackingUp = false;
  String? _lastError;
  Timer? _timer;
  bool _disposed = false;

  /// 记录上次已落盘的本机收藏引用，仅在真正变化时立即重写落盘。
  List<SpotifyTrack>? _lastLocalLiked;
  List<SpotifyPlaylist>? _lastLocalPlaylists;

  PlaylistBackupService(
    this._storage, {
    LibraryProvider? library,
    PreferencesProvider? preferences,
    BackupRemoteFetcher? remoteFetcher,
    SpDcBackupFetcher? sessionFetcher,
    File? diskFile,
    DateTime Function()? now,
    bool? enablePeriodicTimer,
  }) : _library = library,
       _preferences = preferences,
       _customRemoteFetcher = remoteFetcher,
       _sessionFetcher = sessionFetcher ?? SpDcBackupFetcher(),
       _diskFile = diskFile,
       _now = now ?? DateTime.now,
       _enablePeriodicTimer =
           enablePeriodicTimer ??
           !Platform.environment.containsKey('FLUTTER_TEST') {
    _loadFromDisk();
    final prefs =
        _preferences?.prefs ?? AppPreferences.decode(_storage.preferencesJson);
    _enabled = prefs.backupEnabled;
    _autoCurrentAccount = prefs.backupAutoCurrentAccount;
    _intervalMinutes = max(minIntervalMinutes, prefs.backupIntervalMinutes);

    _library?.addListener(_onLibraryChanged);
    _preferences?.addListener(_onPreferencesChanged);
    _rescheduleTimer();
    if (_enabled && _autoCurrentAccount) {
      _backupCurrentAccountImmediate();
    }
  }

  List<BackupAccount> get accounts => _accounts;
  bool get enabled => _enabled;
  bool get autoCurrentAccount => _autoCurrentAccount;
  int get intervalMinutes => _intervalMinutes;
  Duration get effectiveInterval =>
      Duration(minutes: max(minIntervalMinutes, _intervalMinutes));
  bool get isBackingUp => _isBackingUp;
  String? get lastError => _lastError;

  /// 所有账号已落盘的备份歌单汇总（可直接用 [PlaylistDetailScreen] 离线打开，不走云端预览）。
  List<SpotifyPlaylist> get allBackedUpPlaylists => [
    for (final account in _accounts) ...account.backedUpPlaylists,
  ];

  void clearError() {
    if (_lastError == null) return;
    _lastError = null;
    _notify();
  }

  /// 更新备份开关与频率配置（测试或未挂 PreferencesProvider 时也可直接调用）。
  void configure({
    bool? enabled,
    bool? autoCurrentAccount,
    int? intervalMinutes,
  }) {
    final prevEnabled = _enabled;
    final prevAuto = _autoCurrentAccount;
    final prevInterval = _intervalMinutes;

    if (enabled != null) _enabled = enabled;
    if (autoCurrentAccount != null) _autoCurrentAccount = autoCurrentAccount;
    if (intervalMinutes != null) {
      _intervalMinutes = max(minIntervalMinutes, intervalMinutes);
    }

    if (prevEnabled != _enabled || prevInterval != _intervalMinutes) {
      _rescheduleTimer();
    }
    if (_enabled && _autoCurrentAccount && (!prevEnabled || !prevAuto)) {
      _backupCurrentAccountImmediate();
    } else {
      _notify();
    }
  }

  void _onPreferencesChanged() {
    final prefs = _preferences?.prefs;
    if (prefs == null) return;
    configure(
      enabled: prefs.backupEnabled,
      autoCurrentAccount: prefs.backupAutoCurrentAccount,
      intervalMinutes: prefs.backupIntervalMinutes,
    );
  }

  /// 本机账号的收藏歌曲或歌单发生任何增删改时，立即落盘，不等定时轮询。
  void _onLibraryChanged() {
    if (!_enabled || !_autoCurrentAccount) return;
    final library = _library;
    if (library == null) return;
    if (identical(library.likedTracks, _lastLocalLiked) &&
        identical(library.playlists, _lastLocalPlaylists)) {
      return;
    }
    _backupCurrentAccountImmediate();
  }

  void _backupCurrentAccountImmediate() {
    final library = _library;
    if (library == null) return;
    final liked = library.likedTracks;
    // 只备份非 `backup_` 前缀的歌单，避免把外部备份同步进来的副本再套一层
    final playlists = library.playlists
        .where((p) => !p.id.startsWith('backup_'))
        .toList();
    _lastLocalLiked = liked;
    _lastLocalPlaylists = library.playlists;

    final rawId = _storage.username.trim();
    final email = _storage.email.trim();
    final id = rawId.isNotEmpty
        ? rawId
        : (email.isNotEmpty ? email : BackupAccount.localAccountFallbackId);
    final displayName = _storage.displayName.trim().isNotEmpty
        ? _storage.displayName.trim()
        : (email.isNotEmpty ? email : (rawId.isNotEmpty ? rawId : '本机账号'));
    final avatarUrl = _storage.avatarUrl;

    final existingIndex = _accounts.indexWhere((a) => a.isCurrentAccount);
    final updated = BackupAccount(
      id: id,
      email: email,
      displayName: displayName,
      avatarUrl: avatarUrl,
      isCurrentAccount: true,
      syncToLocal: existingIndex >= 0
          ? _accounts[existingIndex].syncToLocal
          : true,
      lastBackupAt: _now(),
      likedTracks: List.unmodifiable(liked),
      playlists: List.unmodifiable(playlists),
    );

    if (existingIndex >= 0) {
      _accounts = [..._accounts]..[existingIndex] = updated;
    } else {
      _accounts = [updated, ..._accounts];
    }
    _persistToDisk();
    _notify();
  }

  Future<BackupAccountSnapshot> _fetchSnapshot(
    BackupSessionCredentials credentials,
  ) {
    final custom = _customRemoteFetcher;
    if (custom != null) {
      return custom(credentials.spDc);
    }
    return _sessionFetcher.fetchWithSession(credentials);
  }

  /// 通过独立 WebView 拿到的会话凭据添加（或更新）外部备份账号，按唯一识别符（邮箱 / 唯一 ID）去重并落盘。
  Future<BackupAccount> addAccountWithSession(
    BackupSessionCredentials credentials,
  ) async {
    final cleanSpDc = credentials.spDc.trim();
    if (cleanSpDc.isEmpty && credentials.accessToken.trim().isEmpty) {
      throw ArgumentError('WebView 会话凭据不能为空');
    }
    _isBackingUp = true;
    _lastError = null;
    _notify();
    try {
      final snapshot = await _fetchSnapshot(credentials);
      final resolvedEmail = snapshot.email.trim().isNotEmpty
          ? snapshot.email.trim()
          : credentials.email.trim();
      final resolvedId = snapshot.id.trim().isNotEmpty
          ? snapshot.id.trim()
          : credentials.userId.trim();
      // 按唯一识别符（id 或 email）查找已有外部账号，同名（displayName 相同）的不同账号绝不互相覆盖
      final existingIndex = _accounts.indexWhere(
        (a) =>
            !a.isCurrentAccount &&
            a.matchesIdentity(otherId: resolvedId, otherEmail: resolvedEmail),
      );
      final account = BackupAccount(
        id: resolvedId,
        email: resolvedEmail,
        displayName: snapshot.displayName,
        avatarUrl: snapshot.avatarUrl,
        spDc: cleanSpDc,
        accessToken: credentials.accessToken.trim(),
        clientToken: credentials.clientToken.trim(),
        profileDir: credentials.profileDir.isNotEmpty
            ? credentials.profileDir
            : (existingIndex >= 0 ? _accounts[existingIndex].profileDir : ''),
        isCurrentAccount: false,
        syncToLocal: existingIndex >= 0
            ? _accounts[existingIndex].syncToLocal
            : true,
        lastBackupAt: _now(),
        likedTracks: List.unmodifiable(snapshot.likedTracks),
        playlists: List.unmodifiable(snapshot.playlists),
      );
      if (existingIndex >= 0) {
        _accounts = [..._accounts]..[existingIndex] = account;
      } else {
        _accounts = [..._accounts, account];
      }
      _persistToDisk();
      return account;
    } catch (e) {
      _lastError = '备份账号失败：$e';
      rethrow;
    } finally {
      _isBackingUp = false;
      _notify();
    }
  }

  /// 兼容仅传 `spDc` 的添加方式。
  Future<BackupAccount> addAccountWithSpDc(
    String spDc, {
    String accessToken = '',
    String clientToken = '',
    String userId = '',
    String email = '',
    String displayName = '',
    String avatarUrl = '',
    String profileDir = '',
  }) => addAccountWithSession(
    BackupSessionCredentials(
      spDc: spDc,
      accessToken: accessToken,
      clientToken: clientToken,
      userId: userId,
      email: email,
      displayName: displayName,
      avatarUrl: avatarUrl,
      profileDir: profileDir,
    ),
  );

  /// 立即执行一次全量备份（本机账号 + 所有已添加的外部账号）并落盘。
  Future<void> backupAllAccounts() async {
    if (_isBackingUp) return;
    _isBackingUp = true;
    _lastError = null;
    _notify();
    try {
      if (_autoCurrentAccount) {
        _backupCurrentAccountImmediate();
      }
      final updated = <BackupAccount>[];
      for (final account in _accounts) {
        if (account.isCurrentAccount ||
            (account.spDc.isEmpty && account.accessToken.isEmpty)) {
          updated.add(account);
          continue;
        }
        try {
          final snapshot = await _fetchSnapshot(
            BackupSessionCredentials(
              spDc: account.spDc,
              accessToken: account.accessToken,
              clientToken: account.clientToken,
              userId: account.id,
              email: account.email,
              displayName: account.displayName,
              avatarUrl: account.avatarUrl,
              profileDir: account.profileDir,
            ),
          );
          updated.add(
            account.copyWith(
              id: snapshot.id.isNotEmpty ? snapshot.id : account.id,
              email: snapshot.email.isNotEmpty ? snapshot.email : account.email,
              displayName: snapshot.displayName,
              avatarUrl: snapshot.avatarUrl,
              lastBackupAt: _now(),
              likedTracks: List.unmodifiable(snapshot.likedTracks),
              playlists: List.unmodifiable(snapshot.playlists),
            ),
          );
        } catch (e) {
          _lastError ??= '账号 ${account.title} 备份失败：$e';
          updated.add(account);
        }
      }
      _accounts = List.unmodifiable(updated);
      _persistToDisk();
    } finally {
      _isBackingUp = false;
      _notify();
    }
  }

  /// 一键将已备份的歌单与已收藏歌曲同步到本机当前账号。
  Future<BackupSyncResult> syncToCurrentAccount() async {
    final library = _library;
    if (library == null) {
      return const BackupSyncResult(addedLikedTracks: 0, syncedPlaylists: 0);
    }
    var addedTracks = 0;
    var syncedPlaylists = 0;

    // 先暂停本机自动备份的即时回写，避免同步中途反复触发无意义的中间态写盘
    final wasAuto = _autoCurrentAccount;
    _autoCurrentAccount = false;
    try {
      for (final account in _accounts) {
        if (!account.syncToLocal) continue;
        // 1. 合并该备份账号的「已收藏的歌曲」到本账号 Liked Songs（倒序添加以保持原先后顺序）
        for (final track in account.likedTracks.reversed) {
          if (track.id.isNotEmpty && !library.isLiked(track.id)) {
            library.toggleLike(track);
            addedTracks++;
          }
        }
        // 2. 外部账号的「已收藏的歌曲」同时作为一张以唯一识别符命名的独立备份歌单落到本账号歌单列表
        if (!account.isCurrentAccount && account.likedTracks.isNotEmpty) {
          library.upsertLocalPlaylist(account.likedSongsPlaylist);
          syncedPlaylists++;
        }
        // 3. 同步该账号备份的所有收藏歌单（含完整曲目，以唯一识别符作为键前缀与所有者标注）到本账号
        for (final playlist in account.playlists) {
          final synced = playlist.copyWith(
            id: playlist.id.startsWith('local_') ||
                    playlist.id.startsWith('backup_')
                ? playlist.id
                : 'backup_${account.uniqueId}_${playlist.id}',
            ownerName: account.title,
            totalTracks: playlist.tracks.length,
          );
          library.upsertLocalPlaylist(synced);
          syncedPlaylists++;
        }
      }
    } finally {
      _autoCurrentAccount = wasAuto;
    }

    if (_enabled && _autoCurrentAccount) {
      _backupCurrentAccountImmediate();
    } else {
      _notify();
    }
    return BackupSyncResult(
      addedLikedTracks: addedTracks,
      syncedPlaylists: syncedPlaylists,
    );
  }

  void setAccountSyncEnabled(String accountKey, bool syncToLocal) {
    final index = _accounts.indexWhere(
      (a) => a.uniqueId == accountKey || a.id == accountKey,
    );
    if (index < 0) return;
    _accounts = [..._accounts]
      ..[index] = _accounts[index].copyWith(syncToLocal: syncToLocal);
    _persistToDisk();
    _notify();
  }

  void removeAccount(String accountKey) {
    final before = _accounts.length;
    _accounts = _accounts
        .where((a) => a.uniqueId != accountKey && a.id != accountKey)
        .toList();
    if (_accounts.length == before) return;
    _persistToDisk();
    _notify();
  }

  void _rescheduleTimer() {
    _timer?.cancel();
    _timer = null;
    if (!_enabled || !_enablePeriodicTimer) return;
    _timer = Timer.periodic(effectiveInterval, (_) {
      unawaited(backupAllAccounts());
    });
  }

  void _loadFromDisk() {
    final file = _diskFile;
    if (file != null && file.existsSync()) {
      try {
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is List) {
          _accounts = List.unmodifiable(
            decoded
                .whereType<Map<String, dynamic>>()
                .map(BackupAccount.fromJson),
          );
          return;
        }
      } catch (_) {}
    }
    final list = _storage.readJsonList(StorageService.keyPlaylistBackups);
    _accounts = List.unmodifiable(list.map(BackupAccount.fromJson));
  }

  void _persistToDisk() {
    final serialized = [for (final a in _accounts) a.toJson()];
    unawaited(
      _storage.writeJsonList(StorageService.keyPlaylistBackups, serialized),
    );
    final file = _diskFile;
    if (file != null) {
      try {
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(jsonEncode(serialized));
      } catch (_) {}
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _library?.removeListener(_onLibraryChanged);
    _preferences?.removeListener(_onPreferencesChanged);
    super.dispose();
  }
}
