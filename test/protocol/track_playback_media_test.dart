import 'dart:convert';

import 'package:flutify_app/services/protocol/track_playback_media.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  PlaybackFile f(String key, int bitrate, {String? encodingId}) => PlaybackFile(
    fileIdHex: 'ab$bitrate',
    format: 10,
    bitrate: bitrate,
    formatKey: key,
    encodingId: encodingId,
  );

  group('TrackPlaybackMedia.selectCbcsForFairPlay', () {
    test('只取 file_ids_mp4_cbcs 分组，选最低码率', () {
      final media = TrackPlaybackMedia(
        name: 't',
        durationMs: 1000,
        mp4Files: [
          f('file_ids_mp4', 96000),
          f('file_ids_mp4_cbcs', 256000),
          f('file_ids_mp4_cbcs', 128000),
        ],
      );
      final sel = media.selectCbcsForFairPlay();
      expect(sel, isNotNull);
      expect(sel!.bitrate, 128000);
      expect(sel.formatKey, 'file_ids_mp4_cbcs');
    });

    test('无 cbcs 分组 → null（macOS 判定「不可用」）', () {
      final media = TrackPlaybackMedia(
        name: 't',
        durationMs: 1000,
        mp4Files: [f('file_ids_mp4', 96000), f('file_ids_mp4', 256000)],
      );
      expect(media.selectCbcsForFairPlay(), isNull);
    });

  });
  group('TrackPlaybackMedia.selectForFree', () {
    for (final reversed in [false, true]) {
      test('同码率 CBCS 不参与 Widevine 选择，倒序=$reversed', () {
        final files = [
          f('file_ids_mp4_cbcs', 128000),
          f('file_ids_mp4', 128000),
          f('file_ids_mp4', 256000),
          f('file_ids_mp4_cbcs', 256000),
        ];
        final media = TrackPlaybackMedia(
          name: 't',
          durationMs: 1000,
          mp4Files: reversed ? files.reversed.toList() : files,
        );
        final selected = media.selectForFree()!;
        expect(selected.formatKey, 'file_ids_mp4');
        expect(selected.bitrate, 128000);
      });
    }
    test('CBCS 码率更低时仍选 CENC 中的最低码率', () {
      final media = TrackPlaybackMedia(
        name: 't',
        durationMs: 1000,
        mp4Files: [
          f('file_ids_mp4_cbcs', 96000),
          f('file_ids_mp4', 256000),
          f('file_ids_mp4', 128000),
        ],
      );
      expect(media.selectForFree()!.bitrate, 128000);
      expect(media.selectForFree()!.formatKey, 'file_ids_mp4');
    });
    test('缺少已知 CENC 分组时返回不可用', () {
      for (final files in <List<PlaybackFile>>[
        [],
        [f('file_ids_mp4_cbcs', 128000)],
        [f('file_ids_mp4_unknown', 128000)],
        [f('', 128000)],
      ]) {
        expect(
          TrackPlaybackMedia(
            name: 't',
            durationMs: 1000,
            mp4Files: files,
          ).selectForFree(),
          isNull,
        );
      }
    });
  });
  group('fetchTrackPlaybackMedia 解析', () {
    Future<TrackPlaybackMedia> parse(List<Map<String, dynamic>> files) {
      const uri = 'spotify:track:abc';
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'media': {
              uri: {
                'item': {
                  'metadata': {'name': 'n', 'duration': 1000},
                  'manifest': {'file_ids_mp4': files},
                },
              },
            },
          }),
          200,
        ),
      );
      return fetchTrackPlaybackMedia(
        'abc',
        headers: () async => {},
        client: client,
      );
    }

    test('地区替换成另一个曲目编号时仍解析该清单', () async {
      const requested = 'spotify:track:5RIm39lsep2lytUpjGogdE';
      const linked = 'spotify:track:4COAOWTtlt8WgtA7AoxSeT';
      final client = MockClient((request) async {
        expect(request.url.path, endsWith(requested));
        return http.Response(
          jsonEncode({
            'media': {
              linked: {
                'item': {
                  'metadata': {'name': "J'adore Venise", 'duration': 180000},
                  'manifest': {
                    'file_ids_mp4': [
                      {'file_id': 'aa', 'format': 2, 'bitrate': 96000},
                    ],
                  },
                },
              },
            },
          }),
          200,
        );
      });
      final media = await fetchTrackPlaybackMedia(
        requested,
        headers: () async => {},
        client: client,
      );
      expect(media.name, "J'adore Venise");
      expect(media.durationMs, 180000);
      expect(media.mp4Files.single.fileIdHex, 'aa');
    });

    test('原编号已有清单时不改用替换编号', () async {
      const requested = 'spotify:track:original';
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'media': {
              'spotify:track:linked': {
                'item': {
                  'metadata': {'name': 'linked', 'duration': 1},
                  'manifest': {
                    'file_ids_mp4': [
                      {'file_id': 'bb', 'format': 2, 'bitrate': 96000},
                    ],
                  },
                },
              },
              requested: {
                'item': {
                  'metadata': {'name': 'original', 'duration': 2},
                  'manifest': {
                    'file_ids_mp4': [
                      {'file_id': 'aa', 'format': 2, 'bitrate': 128000},
                    ],
                  },
                },
              },
            },
          }),
          200,
        ),
      );
      final media = await fetchTrackPlaybackMedia(
        requested,
        headers: () async => {},
        client: client,
      );
      expect(media.name, 'original');
      expect(media.mp4Files.single.fileIdHex, 'aa');
    });

    test('encoding_id 为数字 / 对象时不抛 TypeError，按字符串保留', () async {
      final media = await parse([
        {'file_id': 'aa', 'format': 10, 'bitrate': 96000, 'encoding_id': 42},
        {
          'file_id': 'bb',
          'format': 10,
          'bitrate': 128000,
          'encoding_id': {'k': 1},
        },
        {
          'file_id': 'cc',
          'format': 10,
          'bitrate': 256000,
          'encoding_id': 'enc',
        },
        {'file_id': 'dd', 'format': 10, 'bitrate': 320000},
      ]);
      expect(media.mp4Files.map((f) => f.encodingId).toList(), [
        '42',
        '{k: 1}',
        'enc',
        null,
      ]);
    });
  });
}
