import 'dart:typed_data';

import '../../core/rust_core.dart';
import '../../src/rust/api/protocol.dart' as rust;

/// Fixed diagnostic codes, safe to log without media bytes or arbitrary input.
enum CencFormatFailure { unsupportedCodec, unsupportedEncryptionScheme }

class CencFormatException extends FormatException {
  const CencFormatException(this.failure) : super('Unsupported CENC format');

  final CencFormatFailure failure;
}

/// A bounded parser for the single-track, fragmented AAC/CENC files delivered
/// by the current audio source. Unsupported layouts fail before any rewriting.
/// In particular, an absent senc is clear only for an explicitly clear sample
/// description; it must never silently make an encrypted fragment playable.
class CencAudio {
  CencAudio._(this.bytes);

  final Uint8List bytes;
  final List<CencSample> samples = [];
  final List<({int offset, String type})> _patches = [];
  late Uint8List pssh;

  static CencAudio parse(Uint8List bytes) {
    final audio = CencAudio._(bytes);
    if (RustCore.ready) {
      audio._parseViaRust();
      return audio;
    }
    audio._parse();
    return audio;
  }

  void _parseViaRust() {
    try {
      final parsed = rust.parseCencAudio(bytes: bytes);
      pssh = parsed.pssh;
      for (final s in parsed.samples) {
        final subs = <({int clear, int cipher})>[
          for (var i = 0; i < s.subsampleClear.length && i < s.subsampleCipher.length; i++)
            (clear: s.subsampleClear[i], cipher: s.subsampleCipher[i]),
        ];
        samples.add(CencSample(s.offset, s.size, s.kid, s.iv, subs));
      }
      for (final p in parsed.patches) {
        _patches.add((offset: p.offset, type: p.boxType));
      }
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('UNSUPPORTED_CODEC')) {
        throw const CencFormatException(CencFormatFailure.unsupportedCodec);
      }
      if (msg.contains('UNSUPPORTED_ENCRYPTION_SCHEME')) {
        throw const CencFormatException(
          CencFormatFailure.unsupportedEncryptionScheme,
        );
      }
      throw FormatException(msg);
    }
  }

  int _u32(int at) => ByteData.sublistView(bytes).getUint32(at);
  int _u64(int at) => ByteData.sublistView(bytes).getUint64(at);
  String _type(int at) => String.fromCharCodes(bytes.sublist(at, at + 4));
  Never _bad(String detail) => throw FormatException('CENC: $detail');

  List<_Box> _boxes(int start, int end) {
    final boxes = <_Box>[];
    var at = start;
    while (at < end) {
      if (end - at < 8) _bad('truncated box header');
      var size = _u32(at);
      var header = 8;
      if (size == 1) {
        if (end - at < 16) _bad('truncated extended box');
        size = _u64(at + 8);
        header = 16;
      } else if (size == 0) {
        size = end - at;
      }
      if (size < header || size > end - at) _bad('invalid box length');
      boxes.add(_Box(_type(at + 4), at, at + header, at + size));
      at += size;
    }
    return boxes;
  }

  List<_Box> _children(_Box box) => _boxes(box.body, box.end);
  _Box _one(List<_Box> boxes, String type) {
    final found = boxes.where((b) => b.type == type).toList();
    if (found.length != 1) _bad('expected one $type');
    return found.single;
  }

  _Box _path(_Box box, List<String> path) {
    for (final type in path) {
      box = _one(_children(box), type);
    }
    return box;
  }

  void _min(_Box box, int size) {
    if (box.end - box.body < size) _bad('short ${box.type}');
  }

  void _free(_Box box) => _patches.add((offset: box.start + 4, type: 'free'));

  void _parse() {
    if (bytes.length > 64 * 1024 * 1024) _bad('experimental limit is 64 MiB');
    final top = _boxes(0, bytes.length);
    final moov = _one(top, 'moov');
    final trak = _one(_children(moov), 'trak');
    final tkhd = _path(trak, ['tkhd']);
    _min(tkhd, 24);
    final trackId = _u32(tkhd.body + (bytes[tkhd.body] == 1 ? 20 : 12));
    final hdlr = _path(trak, ['mdia', 'hdlr']);
    _min(hdlr, 12);
    if (_type(hdlr.body + 8) != 'soun') _bad('expected audio track');
    final stsd = _path(trak, ['mdia', 'minf', 'stbl', 'stsd']);
    _min(stsd, 8);
    final entries = _boxes(stsd.body + 8, stsd.end);
    if (entries.length != _u32(stsd.body + 4)) _bad('sample description count');
    final descriptions = <_Encryption?>[];
    for (final entry in entries) {
      if (entry.type == 'mp4a') {
        descriptions.add(null);
        continue;
      }
      if (entry.type != 'enca') _bad('unsupported audio codec');
      _min(entry, 28);
      if (bytes[entry.body + 8] != 0 || bytes[entry.body + 9] != 0) {
        _bad('unsupported audio sample entry version');
      }
      final sinf = _one(_boxes(entry.body + 28, entry.end), 'sinf');
      final frma = _path(sinf, ['frma']);
      final schm = _path(sinf, ['schm']);
      _min(frma, 4);
      _min(schm, 8);
      if (_type(frma.body) != 'mp4a') {
        throw const CencFormatException(CencFormatFailure.unsupportedCodec);
      }
      if (_type(schm.body + 4) != 'cenc') {
        throw const CencFormatException(
          CencFormatFailure.unsupportedEncryptionScheme,
        );
      }
      final tenc = _path(sinf, ['schi', 'tenc']);
      _min(tenc, 24);
      if (bytes[tenc.body] != 0 || bytes[tenc.body + 6] != 1) {
        _bad('unsupported tenc version or protection');
      }
      final ivSize = bytes[tenc.body + 7];
      if (ivSize != 8 && ivSize != 16) _bad('unsupported IV size');
      descriptions.add(
        _Encryption(
          ivSize,
          Uint8List.sublistView(bytes, tenc.body + 8, tenc.body + 24),
        ),
      );
      _patches.add((offset: entry.start + 4, type: 'mp4a'));
      _free(sinf);
    }
    final trex = _path(moov, ['mvex', 'trex']);
    _min(trex, 24);
    if (_u32(trex.body + 4) != trackId) _bad('trex track mismatch');
    final defaultDescription = _u32(trex.body + 8);
    final defaultSize = _u32(trex.body + 16);

    const widevine = [
      0xed,
      0xef,
      0x8b,
      0xa9,
      0x79,
      0xd6,
      0x4a,
      0xce,
      0xa3,
      0xc8,
      0x27,
      0xdc,
      0xd5,
      0x1d,
      0x21,
      0xed,
    ];
    final psshs = [...top, ..._children(moov)].where((b) => b.type == 'pssh');
    Uint8List? initData;
    for (final box in psshs) {
      _min(box, 24);
      if (Iterable<int>.generate(
        16,
      ).every((i) => bytes[box.body + 4 + i] == widevine[i])) {
        initData = Uint8List.sublistView(bytes, box.start, box.end);
      }
      _free(box);
    }
    if (initData == null) _bad('missing Widevine PSSH');
    pssh = initData;
    final mdats = top.where((b) => b.type == 'mdat').toList();
    var previousEnd = 0;
    for (final moof in top.where((b) => b.type == 'moof')) {
      final traf = _path(moof, ['traf']);
      final children = _children(traf);
      for (final box in children.where(
        (b) => b.type == 'sgpd' || b.type == 'sbgp',
      )) {
        _min(box, 8);
        if (_type(box.body + 4) == 'seig')
          _bad('key rotation is not supported');
      }
      final tfhd = _one(children, 'tfhd');
      _min(tfhd, 8);
      final flags = _u32(tfhd.body) & 0xffffff;
      if (_u32(tfhd.body + 4) != trackId) _bad('fragment track mismatch');
      if ((flags & ~0x03003b) != 0) _bad('unsupported tfhd flags');
      final reader = _Cursor(bytes, tfhd.body + 8, tfhd.end);
      final base = flags & 1 != 0 ? reader.u64() : moof.start;
      // First (and only) traf has implicit moof base per ISO BMFF.
      final description = flags & 2 != 0 ? reader.u32() : defaultDescription;
      if (description < 1 || description > descriptions.length)
        _bad('invalid description index');
      final encryption = descriptions[description - 1];
      if (flags & 8 != 0) reader.u32(); // default sample duration
      final sampleSize = flags & 0x10 != 0 ? reader.u32() : defaultSize;
      if (flags & 0x20 != 0) reader.u32();
      final positions = <({int offset, int size})>[];
      int? nextOffset;
      for (final trun in children.where((b) => b.type == 'trun')) {
        _min(trun, 8);
        final runFlags = _u32(trun.body) & 0xffffff;
        if ((runFlags & ~0xf05) != 0) _bad('unsupported trun flags');
        final run = _Cursor(bytes, trun.body + 4, trun.end);
        final count = run.u32();
        if (count > 100000) _bad('sample count exceeds limit');
        final runOffset = runFlags & 1 != 0 ? base + run.i32() : nextOffset;
        if (runOffset == null) _bad('missing first data offset');
        var offset = runOffset;
        if (runFlags & 4 != 0) run.u32();
        for (var i = 0; i < count; i++) {
          if (runFlags & 0x100 != 0) run.u32();
          final size = runFlags & 0x200 != 0 ? run.u32() : sampleSize;
          if (runFlags & 0x400 != 0) run.u32();
          if (runFlags & 0x800 != 0) run.u32();
          if (size <= 0 ||
              size > 1024 * 1024 ||
              offset < previousEnd ||
              !mdats.any((m) => offset >= m.body && offset + size <= m.end)) {
            _bad('sample lies outside mdat or overlaps');
          }
          positions.add((offset: offset, size: size));
          offset += size;
          previousEnd = offset;
        }
        nextOffset = offset;
        run.finish();
      }
      final sencs = children.where((b) => b.type == 'senc').toList();
      if (encryption == null) {
        if (sencs.isNotEmpty) _bad('clear description with senc');
        continue;
      }
      if (sencs.length != 1) _bad('missing sample encryption');
      final senc = sencs.single;
      _min(senc, 8);
      final sencFlags = _u32(senc.body);
      if (sencFlags != 0 && sencFlags != 2) _bad('unsupported senc flags');
      final aux = _Cursor(bytes, senc.body + 4, senc.end);
      if (aux.u32() != positions.length) _bad('senc sample count mismatch');
      for (final position in positions) {
        final iv = aux.blob(encryption.ivSize);
        final subs = <({int clear, int cipher})>[];
        if (sencFlags & 2 != 0) {
          final count = aux.u16();
          for (var i = 0; i < count; i++) {
            subs.add((clear: aux.u16(), cipher: aux.u32()));
          }
          if (subs.isNotEmpty &&
              subs.fold<int>(0, (n, s) => n + s.clear + s.cipher) !=
                  position.size) {
            _bad('subsample sizes do not cover sample');
          }
        }
        samples.add(
          CencSample(position.offset, position.size, encryption.kid, iv, subs),
        );
      }
      aux.finish();
      for (final box in children.where(
        (b) => ['senc', 'saiz', 'saio'].contains(b.type),
      )) {
        _free(box);
      }
    }
    if (samples.isEmpty) _bad('no encrypted samples to verify');
  }

  /// Only call after every encrypted sample has been successfully replaced.
  void markClear(Uint8List output) {
    if (output.length != bytes.length) _bad('output length mismatch');
    for (final patch in _patches) {
      output.setRange(patch.offset, patch.offset + 4, patch.type.codeUnits);
    }
  }
}

class CencSample {
  const CencSample(this.offset, this.size, this.kid, this.iv, this.subsamples);
  final int offset, size;
  final Uint8List kid, iv;
  final List<({int clear, int cipher})> subsamples;
}

class _Encryption {
  _Encryption(this.ivSize, this.kid);
  final int ivSize;
  final Uint8List kid;
}

class _Box {
  _Box(this.type, this.start, this.body, this.end);
  final String type;
  final int start, body, end;
}

class _Cursor {
  _Cursor(this.bytes, this.pos, this.end);
  final Uint8List bytes;
  int pos;
  final int end;
  void need(int size) {
    if (size < 0 || pos + size > end)
      throw const FormatException('CENC: truncated field');
  }

  int u16() {
    need(2);
    final n = ByteData.sublistView(bytes).getUint16(pos);
    pos += 2;
    return n;
  }

  int u32() {
    need(4);
    final n = ByteData.sublistView(bytes).getUint32(pos);
    pos += 4;
    return n;
  }

  int i32() {
    need(4);
    final n = ByteData.sublistView(bytes).getInt32(pos);
    pos += 4;
    return n;
  }

  int u64() {
    need(8);
    final n = ByteData.sublistView(bytes).getUint64(pos);
    pos += 8;
    return n;
  }

  Uint8List blob(int size) {
    need(size);
    final b = Uint8List.sublistView(bytes, pos, pos + size);
    pos += size;
    return b;
  }

  void finish() {
    if (pos != end) throw const FormatException('CENC: extra field bytes');
  }
}
