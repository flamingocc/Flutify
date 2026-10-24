import 'dart:convert';
import 'dart:typed_data';

import '../../core/rust_core.dart';
import '../../src/rust/api/protocol.dart' as rust;

/// Uses the source's HLS initialization data unchanged, just as hls.js and
/// Media3 do. It may carry service metadata absent from the MP4's PSSH.
/// No network URI is fetched here. A malformed Widevine key fails closed.
Uint8List? widevinePsshFromHls(String manifest) {
  if (RustCore.ready) {
    try {
      return rust.widevinePsshFromHls(manifest: manifest);
    } catch (e) {
      throw FormatException(e.toString());
    }
  }
  const systemId = 'edef8ba979d64acea3c827dcd51d21ed';
  const keyFormat = 'urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed';
  const invalid = FormatException('Invalid HLS Widevine initialization data');
  Uint8List? selected;
  final attribute = RegExp(r'(?:^|,)([A-Z0-9-]+)=("[^"]*"|[^,]*)');
  for (final raw in const LineSplitter().convert(manifest)) {
    final line = raw.trim();
    if (!line.startsWith('#EXT-X-KEY:')) continue;
    final attributes = <String, String>{};
    for (final match in attribute.allMatches(line.substring(11))) {
      var value = match[2]!;
      if (value.startsWith('"')) value = value.substring(1, value.length - 1);
      if (attributes.containsKey(match[1])) throw invalid;
      attributes[match[1]!] = value;
    }
    final format = attributes['KEYFORMAT'];
    if (format != keyFormat && format != 'com.widevine.alpha') continue;
    final uri = attributes['URI'];
    if (uri == null || uri.length > 48 * 1024) throw invalid;
    final Uint8List bytes;
    try {
      final data = UriData.parse(uri);
      if (!data.isBase64) throw invalid;
      bytes = data.contentAsBytes();
    } on FormatException {
      throw invalid;
    }
    if (bytes.length < 32 || bytes.length > 32 * 1024) throw invalid;
    final view = ByteData.sublistView(bytes);
    if (view.getUint32(0) != bytes.length ||
        String.fromCharCodes(bytes.sublist(4, 8)) != 'pssh' ||
        bytes[8] > 1 ||
        bytes[9] != 0 ||
        bytes[10] != 0 ||
        bytes[11] != 0 ||
        bytes
                .sublist(12, 28)
                .map((v) => v.toRadixString(16).padLeft(2, '0'))
                .join() !=
            systemId) {
      throw invalid;
    }
    var offset = 28;
    if (bytes[8] == 1) offset += 4 + view.getUint32(offset) * 16;
    if (offset + 4 > bytes.length ||
        view.getUint32(offset) != bytes.length - offset - 4) {
      throw invalid;
    }
    if (selected != null && base64Encode(selected) != base64Encode(bytes)) {
      throw const FormatException('HLS key rotation is not supported');
    }
    selected = bytes;
  }
  return selected;
}
