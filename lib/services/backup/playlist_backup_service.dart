import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/constants/spotify_endpoints.dart';
import '../../models/app_preferences.dart';
import '../../models/image.dart';
import '../../models/playlist.dart';
import '../../models/track.dart';
import '../../providers/library_provider.dart';
import '../../providers/preferences_provider.dart';
import '../auth/web_token_service.dart';
import '../storage_service.dart';

/// 从独立 WebView 拿到的 `sp_dc` 拉取到的账号资料与收藏快照。
class BackupAccountSnapshot {
  final String id;
  final String displayName;
  final String avatarUrl;
  final List<SpotifyTrack> likedTracks;
  final List<SpotifyPlaylist> playlists;

  const BackupAccountSnapshot({
    required this.id,
    required this.displayName,
    this.avatarUrl = '',
    this.likedTracks = const [],
    this.playlists = const [],
  });
}

typedef BackupRemoteFetcher =
    Future<BackupAccountSnapshot> Function(String spDc);

/// 单个已备份账号的落盘快照（含「已收藏的歌曲」与收藏歌单的完整曲目，不做云端预览）。
@immutable
class BackupAccount {
  static const String localAccountFallbackId = 'local_current_account';

  final String id;
  final String displayName;
  final String avatarUrl;

  /// 独立 WebView 登录捕获的 `sp_dc`（本机当前账号为空，直接读 [LibraryProvider]）。
  final String spDc;

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
    this.avatarUrl = '',
    this.spDc = '',
    this.profileDir = '',
    this.isCurrentAccount = false,
    this.syncToLocal = true,
    this.lastBackupAt,
    this.likedTracks = const [],
    this.playlists = const [],
  });

  String get title => displayName.isNotEmpty ? displayName : id;

  /// 该账号已备份的「已收藏的歌曲」，包装为可直接用 [PlaylistDetailScreen] 打开的本机落盘歌单。
  SpotifyPlaylist get likedSongsPlaylist => SpotifyPlaylist(
    id: 'backup_${id}_liked',
    name: '$title · 已收藏的歌曲',
    uri: 'spotify:playlist:backup_${id}_liked',
    ownerName: title,
    images: const [
      SpotifyImage(url: 'https://misc.scdn.co/liked-songs/liked-songs-640.png'),
    ],
    tracks: likedTracks,
    totalTracks: likedTracks.length,
    primaryColor: '#450af5',
  );

  /// 该账号所有已落盘的备份歌单（含「已收藏的歌曲」与各收藏歌单，id 均以 `backup_` 开头以防触发云端预览）。
  List<SpotifyPlaylist> get backedUpPlaylists => [
    if (likedTracks.isNotEmpty) likedSongsPlaylist,
    for (final p in playlists)
      p.copyWith(
        id: p.id.startsWith('backup_') ? p.id : 'backup_${id}_${p.id}',
        ownerName: p.ownerName.isNotEmpty ? p.ownerName : title,
        totalTracks: p.tracks.length,
      ),
  ];

  BackupAccount copyWith({
    String? id,
    String? displayName,
    String? avatarUrl,
    String? spDc,
    String? profileDir,
    bool? isCurrentAccount,
    bool? syncToLocal,
    DateTime? lastBackupAt,
    List<SpotifyTrack>? likedTracks,
    List<SpotifyPlaylist>? playlists,
  }) {
    return BackupAccount(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      spDc: spDc ?? this.spDc,
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
    'displayName': displayName,
    'avatarUrl': avatarUrl,
    'spDc': spDc,
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
      displayName: json['displayName'] as String? ?? '',
      avatarUrl: json['avatarUrl'] as String? ?? '',
      spDc: json['spDc'] as String? ?? '',
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

/// 用独立账号的 `sp_dc` 铸 Web token 并拉取其资料、已收藏歌曲和歌单（含歌单曲目）。
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

  Future<BackupAccountSnapshot> fetch(String spDc) async {
    final minted = await WebTokenService.mintTokenForSpDc(
      spDc,
      client: _client,
    );
    final headers = <String, String>{
      'Authorization': 'Bearer ${minted.token}',
      'Accept': 'application/json',
    };

    final me = await _getJson('$_baseUrl/me', headers);
    final id = (me['id'] as String? ?? '').trim();
    if (id.isEmpty) {
      throw StateError('无法读取备份账号 ID');
    }
    final displayName = (me['display_name'] as String? ?? id).trim();
    var avatarUrl = '';
    final images = me['images'];
    if (images is List &&
        images.isNotEmpty &&
        images.first is Map<String, dynamic>) {
      avatarUrl =
          (images.first as Map<String, dynamic>)['url'] as String? ?? '';
    }

    final likedItems = await _pages(
      '$_baseUrl/me/tracks?limit=$_pageSize',
      headers,
      (json) => json['items'],
    );
    final likedTracks = <SpotifyTrack>[
      for (final item in likedItems)
        if (item is Map<String, dynamic> &&
            item['track'] is Map<String, dynamic>)
          SpotifyTrack.fromJson(
            item['track'] as Map<String, dynamic>,
          ).copyWith(addedAt: SpotifyTrack.parseAddedAt(item['added_at'])),
    ];

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
        } catch (_) {
          // 单个歌单曲目拉取失败不中断整体备份
        }
      }
      playlists.add(playlist);
    }

    return BackupAccountSnapshot(
      id: id,
      displayName: displayName.isNotEmpty ? displayName : id,
      avatarUrl: avatarUrl,
      likedTracks: likedTracks,
      playlists: playlists,
    );
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
/// - 独立 WebView 登录多账号（拿 `sp_dc`）并拉取其「已收藏的歌曲」与歌单落盘；
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
  final BackupRemoteFetcher _remoteFetcher;
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
    File? diskFile,
    DateTime Function()? now,
    bool? enablePeriodicTimer,
  }) : _library = library,
       _preferences = preferences,
       _remoteFetcher = remoteFetcher ?? SpDcBackupFetcher().fetch,
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
    final id = rawId.isNotEmpty ? rawId : BackupAccount.localAccountFallbackId;
    final displayName = _storage.displayName.trim().isNotEmpty
        ? _storage.displayName.trim()
        : (rawId.isNotEmpty ? rawId : '本机账号');
    final avatarUrl = _storage.avatarUrl;

    final existingIndex = _accounts.indexWhere((a) => a.isCurrentAccount);
    final updated = BackupAccount(
      id: id,
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

  /// 通过独立 WebView 拿到的 [spDc] 添加（或更新）一个外部备份账号，并立即拉取收藏歌单落盘。
  Future<BackupAccount> addAccountWithSpDc(
    String spDc, {
    String profileDir = '',
  }) async {
    final cleanSpDc = spDc.trim();
    if (cleanSpDc.isEmpty) {
      throw ArgumentError.value(spDc, 'spDc', 'sp_dc 不能为空');
    }
    _isBackingUp = true;
    _lastError = null;
    _notify();
    try {
      final snapshot = await _remoteFetcher(cleanSpDc);
      final existingIndex = _accounts.indexWhere(
        (a) => !a.isCurrentAccount && a.id == snapshot.id,
      );
      final account = BackupAccount(
        id: snapshot.id,
        displayName: snapshot.displayName,
        avatarUrl: snapshot.avatarUrl,
        spDc: cleanSpDc,
        profileDir: profileDir.isNotEmpty
            ? profileDir
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
        if (account.isCurrentAccount || account.spDc.isEmpty) {
          updated.add(account);
          continue;
        }
        try {
          final snapshot = await _remoteFetcher(account.spDc);
          updated.add(
            account.copyWith(
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
        // 2. 外部账号的「已收藏的歌曲」同时作为一张独立备份歌单落到本账号歌单列表，方便直接点播
        if (!account.isCurrentAccount && account.likedTracks.isNotEmpty) {
          library.upsertLocalPlaylist(account.likedSongsPlaylist);
          syncedPlaylists++;
        }
        // 3. 同步该账号备份的所有收藏歌单（含完整曲目）到本账号
        for (final playlist in account.playlists) {
          final synced = playlist.copyWith(
            id: playlist.id.startsWith('local_') ||
                    playlist.id.startsWith('backup_')
                ? playlist.id
                : 'backup_${account.id}_${playlist.id}',
            ownerName: playlist.ownerName.isNotEmpty
                ? playlist.ownerName
                : account.title,
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

  void setAccountSyncEnabled(String accountId, bool syncToLocal) {
    final index = _accounts.indexWhere((a) => a.id == accountId);
    if (index < 0) return;
    _accounts = [..._accounts]
      ..[index] = _accounts[index].copyWith(syncToLocal: syncToLocal);
    _persistToDisk();
    _notify();
  }

  void removeAccount(String accountId) {
    final before = _accounts.length;
    _accounts = _accounts.where((a) => a.id != accountId).toList();
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
