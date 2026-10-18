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
import '../library/collection_codec.dart';
import '../library/rootlist_parser.dart';
import '../protocol/access_point.dart';
import '../spotify_api_service.dart';
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

/// 单个已备份账号的落盘快照。
///
/// - 主键与展示均采用账户唯一识别符（[uniqueId]：优先邮箱 [email]，其次 Spotify 唯一用户名 [id]），
///   即使多个账号昵称（[displayName]）完全相同也不会冲突或覆盖；
/// - 歌单保留真实的 Spotify 歌单 ID（与分享歌单链接 `https://open.spotify.com/playlist/{id}` 一致），
///   确保导入后可直接查看与播放；
/// - 各账号的「已收藏的歌曲」在 [PlaylistBackupService] 层合并为同一个「已收藏的歌曲」集合。
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

  static String _normalizePlaylistId(String rawId) {
    if (!rawId.startsWith('backup_')) return rawId;
    final rest = rawId.substring('backup_'.length);
    final lastUnderscore = rest.lastIndexOf('_');
    if (lastUnderscore <= 0 || lastUnderscore + 1 >= rest.length) return rawId;
    return rest.substring(lastUnderscore + 1);
  }

  factory BackupAccount.fromJson(Map<String, dynamic> json) {
    final rawLiked = json['likedTracks'];
    final rawPlaylists = json['playlists'];
    final lastBackupRaw = json['lastBackupAt'];
    final playlists = rawPlaylists is List
        ? rawPlaylists
              .whereType<Map<String, dynamic>>()
              .map(SpotifyPlaylist.fromJson)
              .where((p) => !p.id.endsWith('_liked'))
              .map((p) {
                final cleanId = _normalizePlaylistId(p.id);
                return cleanId == p.id
                    ? p
                    : p.copyWith(
                        id: cleanId,
                        uri: 'spotify:playlist:$cleanId',
                      );
              })
              .toList()
        : const <SpotifyPlaylist>[];
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
      playlists: playlists,
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

/// 使用独立 WebView 会话自带的 `accessToken` 读取账户唯一识别符（邮箱 / 用户名 ID）
/// 与收藏列表，并通过分享歌单 API（[SpotifyApiService.getPlaylist]）拉取歌单完整详情与曲目。
class SpDcBackupFetcher {
  static const String _spclient = SpotifyEndpoints.defaultSpClientBase;
  static const int _pageSize = 300;
  static const int _maxPages = 10;
  static const int _trackLimit = 500;
  static const int _playlistLimit = 300;
  static const int _maxPlaylistsWithTracks = 30;

  final http.Client _client;
  final String _baseUrl;
  final SpotifyApiService? _apiService;

  SpDcBackupFetcher({
    http.Client? client,
    String baseUrl = SpotifyEndpoints.defaultWebApiBase,
    SpotifyApiService? apiService,
  }) : _client = client ?? http.Client(),
       _baseUrl = baseUrl,
       _apiService = apiService;

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

    // 2. 读取已收藏的歌曲（collection/v2/paging 取曲目 URI，再用主会话 getTracksByUris 补全详情）
    List<SpotifyTrack> likedTracks = const [];
    if (token.isNotEmpty) {
      likedTracks = await _fetchSpClientLikedTracks(id, headers);
      if (likedTracks.isEmpty) {
        likedTracks = await _fetchWebApiLikedTracks(headers);
      }
    }

    // 3. 读取收藏歌单（rootlist 取歌单 ID / 分享链接，再走分享歌单 API getPlaylist 拉取歌单曲目与封面）
    List<SpotifyPlaylist> playlists = const [];
    if (token.isNotEmpty) {
      playlists = await _fetchSpClientPlaylists(id, headers);
      if (playlists.isEmpty) {
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

  Future<List<SpotifyTrack>> _fetchSpClientLikedTracks(
    String user,
    Map<String, String> headers,
  ) async {
    try {
      final all = <CollectionEntry>[];
      var pageToken = '';
      for (var page = 0; page < _maxPages; page++) {
        final res = await _client.post(
          Uri.parse('$_spclient/collection/v2/paging'),
          headers: {
            ...headers,
            'Content-Type': CollectionCodec.contentType,
            'Accept': CollectionCodec.contentType,
          },
          body: CollectionCodec.encodePageRequest(
            username: user,
            set: CollectionCodec.setCollection,
            token: pageToken,
            limit: _pageSize,
          ),
        );
        if (res.statusCode != 200) break;
        final parsed = CollectionCodec.decodePage(res.bodyBytes);
        all.addAll(parsed.items.where((e) => e.kind == 'track'));
        if (parsed.nextToken.isEmpty || parsed.items.isEmpty) break;
        pageToken = parsed.nextToken;
      }
      if (all.isEmpty) return const [];
      final kept = all.take(_trackLimit).toList();
      final uris = [for (final e in kept) e.uri];
      final addedAt = {
        for (final e in kept)
          if (e.addedAt > 0)
            e.id: DateTime.fromMillisecondsSinceEpoch(e.addedAt * 1000),
      };

      // 用主应用的 SpotifyApiService（已带合法 client-token）批量补全曲目详情
      final api = _apiService;
      if (api != null && api.isConfigured) {
        final tracks = await api.getTracksByUris(uris);
        if (tracks.isNotEmpty) {
          return [
            for (final t in tracks) t.copyWith(addedAt: addedAt[t.id]),
          ];
        }
      }

      // 兜底：按 50 首一批走 /v1/tracks?ids=...
      final ids = [for (final e in kept) if (e.id.isNotEmpty) e.id];
      final resolved = <SpotifyTrack>[];
      for (var i = 0; i < ids.length; i += 50) {
        final batch = ids.sublist(i, min(i + 50, ids.length)).join(',');
        try {
          final json = await _getJson('$_baseUrl/tracks?ids=$batch', headers);
          final list = json['tracks'];
          if (list is List) {
            for (final item in list.whereType<Map<String, dynamic>>()) {
              final track = SpotifyTrack.fromJson(item);
              resolved.add(track.copyWith(addedAt: addedAt[track.id]));
            }
          }
        } catch (_) {}
      }
      return resolved;
    } catch (_) {
      return const [];
    }
  }

  Future<List<SpotifyPlaylist>> _fetchSpClientPlaylists(
    String user,
    Map<String, String> headers,
  ) async {
    try {
      final res = await _client.get(
        Uri.parse(
          '$_spclient/playlist/v2/user/${Uri.encodeComponent(user)}/rootlist'
          '?decorate=revision,attributes,length,owner&from=0&length=$_playlistLimit',
        ),
        headers: headers,
      );
      if (res.statusCode != 200) return const [];
      final json =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final rawPlaylists = RootlistParser.parse(json);
      final api = _apiService;
      final result = <SpotifyPlaylist>[];
      for (final p in rawPlaylists.take(_maxPlaylistsWithTracks)) {
        if (p.id.isEmpty) continue;
        // 走分享歌单 API（按歌单 ID / 分享链接 spotify:playlist:{id}）获取完整歌单与曲目
        if (api != null && api.isConfigured) {
          try {
            final full = await api.getPlaylist(p.id);
            result.add(
              full.copyWith(
                name: full.name.isNotEmpty ? full.name : p.name,
                images: full.images.isNotEmpty ? full.images : p.images,
                totalTracks: full.tracks.isNotEmpty
                    ? full.tracks.length
                    : full.totalTracks,
              ),
            );
            continue;
          } catch (_) {}
        }
        result.add(p);
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  Future<List<SpotifyTrack>> _fetchWebApiLikedTracks(
    Map<String, String> headers,
  ) async {
    try {
      final likedItems = await _pages(
        '$_baseUrl/me/tracks?limit=50',
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
        '$_baseUrl/me/playlists?limit=50',
        headers,
        (json) => json['items'],
      );
      final playlists = <SpotifyPlaylist>[];
      for (final item in rawPlaylists.take(_maxPlaylistsWithTracks)) {
        if (item is! Map<String, dynamic>) continue;
        var playlist = SpotifyPlaylist.fromJson(item);
        if (playlist.id.isEmpty) continue;
        if (playlist.tracks.isEmpty) {
          final api = _apiService;
          if (api != null && api.isConfigured) {
            try {
              final full = await api.getPlaylist(playlist.id);
              playlist = full.copyWith(
                name: full.name.isNotEmpty ? full.name : playlist.name,
                images: full.images.isNotEmpty ? full.images : playlist.images,
              );
              playlists.add(playlist);
              continue;
            } catch (_) {}
          }
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
    int maxPages = 6,
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
/// - 独立 WebView 登录多账号（直接复用 WebView 会话，不手动铸造 token）并按唯一识别符（邮箱 / 用户名 ID）落盘；
/// - 自动备份本机已登录账号，且**本机收藏更改立即落盘**（不等轮询）；
/// - 「已收藏的歌曲」作为所有账号共有的特殊歌单，统一采用**合并**操作（去重汇总，不拆成多个假歌单）；
/// - 其余歌单保留真实 Spotify 歌单 ID（走分享歌单 API 获取歌单详情），导入后可直接查看与播放。
class PlaylistBackupService extends ChangeNotifier {
  static const int minIntervalMinutes = AppPreferences.minBackupIntervalMinutes;
  static const int defaultIntervalMinutes =
      AppPreferences.defaultBackupIntervalMinutes;
  static const List<int> intervalOptionsMinutes =
      AppPreferences.backupIntervalOptions;

  final StorageService _storage;
  final LibraryProvider? _library;
  final PreferencesProvider? _preferences;
  final SpotifyApiService? _apiService;
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
    SpotifyApiService? apiService,
    BackupRemoteFetcher? remoteFetcher,
    SpDcBackupFetcher? sessionFetcher,
    File? diskFile,
    DateTime Function()? now,
    bool? enablePeriodicTimer,
  }) : _library = library,
       _preferences = preferences,
       _apiService = apiService,
       _customRemoteFetcher = remoteFetcher,
       _sessionFetcher =
           sessionFetcher ?? SpDcBackupFetcher(apiService: apiService),
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
    if (_enabled && _apiService != null) {
      unawaited(_hydrateIncompleteAccounts());
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

  /// 所有备份账号合并后的「已收藏的歌曲」（按曲目 ID 去重）。
  List<SpotifyTrack> get mergedLikedTracks {
    final seen = <String>{};
    final merged = <SpotifyTrack>[];
    for (final account in _accounts) {
      for (final track in account.likedTracks) {
        final key = track.id.isNotEmpty ? track.id : track.uri;
        if (key.isEmpty || seen.add(key)) {
          merged.add(track);
        }
      }
    }
    return merged;
  }

  /// 合并后的「已收藏的歌曲」歌单（可直接打开查看与播放）。
  SpotifyPlaylist get mergedLikedSongsPlaylist {
    final tracks = mergedLikedTracks;
    return SpotifyPlaylist(
      id: LibraryProvider.likedSongsId,
      name: '已收藏的歌曲',
      uri: LibraryProvider.likedSongsUri,
      ownerName: '合并备份',
      images: const [
        SpotifyImage(
          url: 'https://misc.scdn.co/liked-songs/liked-songs-640.png',
        ),
      ],
      tracks: tracks,
      totalTracks: tracks.length,
      primaryColor: '#450af5',
    );
  }

  /// 已落盘的备份歌单汇总：
  /// - 顶部为所有备份账号**合并**后的「已收藏的歌曲」；
  /// - 其余为去重后的各账号收藏歌单（保留真实歌单 ID，走分享歌单链接即可直接查看）。
  List<SpotifyPlaylist> get allBackedUpPlaylists {
    final liked = mergedLikedTracks;
    final seenIds = <String>{};
    final result = <SpotifyPlaylist>[
      if (liked.isNotEmpty) mergedLikedSongsPlaylist,
    ];
    for (final account in _accounts) {
      for (final p in account.playlists) {
        if (p.id.isEmpty || !seenIds.add(p.id)) continue;
        result.add(
          p.copyWith(
            ownerName: p.ownerName.isNotEmpty && p.ownerName != 'Spotify'
                ? p.ownerName
                : account.title,
            totalTracks: p.tracks.isNotEmpty ? p.tracks.length : p.totalTracks,
          ),
        );
      }
    }
    return result;
  }

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
    final playlists = library.playlists
        .where((p) => !p.id.endsWith('_liked'))
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

  /// 若磁盘上已有外部账号的歌单尚未拉取曲目（如旧版本留下的 0 首歌曲记录），后台自动按歌单 ID 补齐落盘。
  Future<void> _hydrateIncompleteAccounts() async {
    final api = _apiService;
    if (api == null || !api.isConfigured) return;
    var changed = false;
    final nextAccounts = <BackupAccount>[];
    for (final account in _accounts) {
      if (account.isCurrentAccount) {
        nextAccounts.add(account);
        continue;
      }
      if (account.likedTracks.isEmpty && account.accessToken.isNotEmpty) {
        try {
          final snap = await _fetchSnapshot(
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
          nextAccounts.add(
            account.copyWith(
              likedTracks: List.unmodifiable(snap.likedTracks),
              playlists: List.unmodifiable(snap.playlists),
              lastBackupAt: _now(),
            ),
          );
          changed = true;
          continue;
        } catch (_) {}
      }
      final updatedPlaylists = <SpotifyPlaylist>[];
      var accountChanged = false;
      for (final p in account.playlists) {
        if (p.tracks.isEmpty && p.id.isNotEmpty && !p.id.startsWith('local_')) {
          try {
            final full = await api.getPlaylist(p.id);
            if (full.tracks.isNotEmpty) {
              updatedPlaylists.add(
                full.copyWith(
                  name: full.name.isNotEmpty ? full.name : p.name,
                  images: full.images.isNotEmpty ? full.images : p.images,
                  totalTracks: full.tracks.length,
                ),
              );
              accountChanged = true;
              continue;
            }
          } catch (_) {}
        }
        updatedPlaylists.add(p);
      }
      if (accountChanged) {
        changed = true;
        nextAccounts.add(
          account.copyWith(playlists: List.unmodifiable(updatedPlaylists)),
        );
      } else {
        nextAccounts.add(account);
      }
    }
    if (changed && !_disposed) {
      _accounts = List.unmodifiable(nextAccounts);
      _persistToDisk();
      _notify();
    }
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
        if (account.isCurrentAccount) {
          updated.add(account);
          continue;
        }
        if (account.spDc.isEmpty && account.accessToken.isEmpty) {
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
      await _hydrateIncompleteAccounts();
    } finally {
      _isBackingUp = false;
      _notify();
    }
  }

  /// 一键将已备份的歌单与已收藏歌曲同步到本机当前账号：
  /// - 各账号的「已收藏的歌曲」直接**合并**进本账号的「已点赞的歌曲」（Liked Songs），不额外拆出假歌单；
  /// - 各账号收藏的普通歌单保留真实 Spotify 歌单 ID 合并进本账号歌单列表。
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
        // 2. 同步该账号备份的所有普通收藏歌单（保留真实歌单 ID，可直接通过分享歌单接口查看和播放）
        for (final playlist in account.playlists) {
          if (playlist.id.isEmpty || playlist.id.endsWith('_liked')) continue;
          final synced = playlist.copyWith(
            uri: playlist.uri.isNotEmpty
                ? playlist.uri
                : 'spotify:playlist:${playlist.id}',
            ownerName: playlist.ownerName.isNotEmpty
                ? playlist.ownerName
                : account.title,
            totalTracks: playlist.tracks.isNotEmpty
                ? playlist.tracks.length
                : playlist.totalTracks,
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
