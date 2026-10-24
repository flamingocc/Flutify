import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../core/rust_core.dart';
import '../audio/audio_engine.dart';
import '../protocol/progressive_download.dart';
import 'cenc_audio.dart';
import 'streaming_download.dart';
import 'windows_cdm_process.dart';
import 'widevine_init_data.dart';

abstract class NativeAudioDecryptor {
  Future<NativeMemoryAudio> decrypt(EmeTrackContent content);
  void cancel();
}

/// First experimental playback implementation: load a bounded, complete fMP4,
/// let the CDM decrypt its samples, then give an in-memory stream to media_kit.
/// No plaintext file or extracted key is produced. Full-file buffering is an
/// intentional limitation until the license/CDM path is proven in practice.
class WindowsNativeDecryptor implements NativeAudioDecryptor {
  WindowsNativeDecryptor({
    required this.fetchCertificate,
    required this.postLicense,
    this.startHost = WindowsCdmProcess.start,
  });

  final Future<Uint8List> Function() fetchCertificate;
  final Future<Uint8List> Function(Uint8List) postLicense;
  final Future<WindowsCdmProcess> Function() startHost;
  WindowsCdmProcess? _host;
  int _generation = 0;

  @override
  void cancel() {
    ++_generation;
    _host?.abort();
    _host = null;
  }

  @override
  Future<NativeMemoryAudio> decrypt(EmeTrackContent content) async {
    cancel();
    final generation = _generation;
    void check() {
      if (generation != _generation) throw const CdmException('cancelled');
    }

    final watch = Stopwatch()..start();
    WindowsCdmProcess? host;
    Uint8List? output;
    try {
      // The source returns early while encrypted bytes are still downloading.
      final download = StreamingDownloads.of(content.m4aPath);
      if (download != null) {
        if (download.expectedTotal > 64 * 1024 * 1024)
          throw const CdmException('file_too_large');
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (!download.done) {
          check();
          if (DateTime.now().isAfter(deadline))
            throw const CdmException('download_timeout');
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        if (download.error != null) throw const CdmException('download_failed');
      }
      check();
      final file = File(content.m4aPath);
      if (await file.length() > 64 * 1024 * 1024)
        throw const CdmException('file_too_large');
      final encrypted = await file.readAsBytes();
      check();
      // 最大 64MB 的同步解析（含 FFI 拷贝）放到后台 Isolate，避免卡住 UI；
      // 结果经 Isolate.exit 传回，不再拷贝。
      final useRust = RustCore.ready;
      // 用顶层函数 + compute：闭包会捕获整个方法上下文（含不可跨 Isolate 发送的对象）
      final audio = await compute(_parseCencOffThread, (encrypted, useRust));
      check();
      final manifestPssh = widevinePsshFromHls(content.m3u8);
      final pssh = manifestPssh ?? audio.pssh;
      debugPrint(
        '[native-wv] CENC parsed encrypted_samples=${audio.samples.length} bytes=${encrypted.length}',
      );
      debugPrint(
        '[native-wv] Init data source=${manifestPssh == null ? 'mp4' : 'hls'} bytes=${pssh.length}',
      );
      host = await startHost();
      check();
      _host = host;
      debugPrint(
        '[native-wv] CDM initialized interface=${host.interfaceVersion}',
      );
      // Fetch every session, so a rotated service certificate is used without
      // an application update or a persistent stale certificate cache.
      final certificate = await fetchCertificate();
      check();
      await host.open(
        certificate: certificate,
        pssh: pssh,
        postLicense: postLicense,
      );
      check();
      debugPrint('[native-wv] License accepted; testing encrypted samples');
      output = Uint8List.fromList(encrypted);
      for (var i = 0; i < audio.samples.length; i += 128) {
        check();
        final batch = audio.samples.sublist(
          i,
          (i + 128).clamp(0, audio.samples.length),
        );
        final plain = await host.decryptBatch(batch, encrypted);
        try {
          check();
          var offset = 0;
          for (final sample in batch) {
            output.setRange(
              sample.offset,
              sample.offset + sample.size,
              plain,
              offset,
            );
            offset += sample.size;
          }
        } finally {
          plain.fillRange(0, plain.length, 0);
        }
      }
      audio.markClear(output);
      debugPrint(
        '[native-wv] Decrypt succeeded samples=${audio.samples.length} elapsed_ms=${watch.elapsedMilliseconds}',
      );
      // Keep the temporary session alive for the lifetime of this playback.
      final memory = NativeMemoryAudio(
        output,
        onDispose: () {
          if (identical(_host, host)) _host = null;
          host!.close().ignore();
        },
      );
      output = null;
      return memory;
    } catch (_) {
      host?.abort();
      if (identical(_host, host)) _host = null;
      output?.fillRange(0, output.length, 0);
      rethrow;
    }
  }
}

class NativeMemoryAudio implements ProgressiveAudio {
  NativeMemoryAudio(this._bytes, {this.onDispose});
  Uint8List? _bytes;
  final void Function()? onDispose;
  @override
  String get contentType => 'audio/mp4';
  @override
  int get length => _bytes?.length ?? 0;
  @override
  double get progress => 1;
  @override
  Future<void> get done => Future.value();
  @override
  Stream<List<int>> read(int start, [int? end]) async* {
    final bytes = _bytes;
    if (bytes == null) throw const CdmException('audio_released');
    final stop = end ?? bytes.length;
    if (start < 0 || stop < start || stop > bytes.length)
      throw RangeError('audio range');
    for (var at = start; at < stop; at += 65536) {
      if (_bytes == null) throw const CdmException('audio_released');
      yield Uint8List.sublistView(bytes, at, (at + 65536).clamp(0, stop));
    }
  }

  void dispose() {
    final bytes = _bytes;
    if (bytes == null) return;
    _bytes = null;
    bytes.fillRange(0, bytes.length, 0);
    onDispose?.call();
  }
}

Future<CencAudio> _parseCencOffThread((Uint8List, bool) args) async {
  final (bytes, useRust) = args;
  if (useRust) await RustCore.initialize(exitOnFailure: false);
  return CencAudio.parse(bytes);
}
