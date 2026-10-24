//! 从 HLS 清单（`#EXT-X-KEY`）提取并校验 Widevine PSSH 初始化数据。
//!
//! 行为与 `lib/services/eme/widevine_init_data.dart` 完全一致。

use std::collections::HashMap;

const WIDEVINE_UUID: [u8; 16] = [
    0xed, 0xef, 0x8b, 0xa9, 0x79, 0xd6, 0x4a, 0xce, 0xa3, 0xc8, 0x27, 0xdc, 0xd5, 0x1d, 0x21, 0xed,
];
const KEY_FORMAT_UUID: &str = "urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed";
const KEY_FORMAT_ALPHA: &str = "com.widevine.alpha";
const INVALID_ERR: &str = "Invalid HLS Widevine initialization data";

fn parse_ext_x_key_attributes(rest: &str) -> Result<HashMap<String, String>, String> {
    let mut attrs = HashMap::new();
    let bytes = rest.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let key_start = i;
        while i < bytes.len()
            && (bytes[i].is_ascii_uppercase() || bytes[i].is_ascii_digit() || bytes[i] == b'-')
        {
            i += 1;
        }
        if i == key_start || i >= bytes.len() || bytes[i] != b'=' {
            // Skip to next comma if malformed segment
            while i < bytes.len() && bytes[i] != b',' {
                i += 1;
            }
            if i < bytes.len() && bytes[i] == b',' {
                i += 1;
            }
            continue;
        }
        let key = rest[key_start..i].to_string();
        i += 1; // skip '='

        let val = if i < bytes.len() && bytes[i] == b'"' {
            i += 1;
            let val_start = i;
            while i < bytes.len() && bytes[i] != b'"' {
                i += 1;
            }
            if i >= bytes.len() {
                return Err(INVALID_ERR.to_string());
            }
            let v = rest[val_start..i].to_string();
            i += 1; // skip closing '"'
            v
        } else {
            let val_start = i;
            while i < bytes.len() && bytes[i] != b',' {
                i += 1;
            }
            rest[val_start..i].to_string()
        };

        if attrs.insert(key, val).is_some() {
            return Err(INVALID_ERR.to_string());
        }
        if i < bytes.len() {
            if bytes[i] == b',' {
                i += 1;
            } else {
                return Err(INVALID_ERR.to_string());
            }
        }
    }
    Ok(attrs)
}

fn decode_base64_data_uri(uri: &str) -> Result<Vec<u8>, String> {
    let trimmed = uri.trim();
    if trimmed.len() < 5 || !trimmed[..5].eq_ignore_ascii_case("data:") {
        return Err(INVALID_ERR.to_string());
    }
    let comma = trimmed.find(',').ok_or_else(|| INVALID_ERR.to_string())?;
    let meta = &trimmed[5..comma];
    let has_base64 = meta
        .split(';')
        .any(|part| part.trim().eq_ignore_ascii_case("base64"));
    if !has_base64 {
        return Err(INVALID_ERR.to_string());
    }
    let payload = &trimmed[comma + 1..];
    decode_base64(payload).ok_or_else(|| INVALID_ERR.to_string())
}

fn decode_base64(input: &str) -> Option<Vec<u8>> {
    // Handle percent-encoding (e.g. %2B, %2F, %3D) just like Dart UriData.parse
    let mut cleaned = Vec::with_capacity(input.len());
    let raw = input.as_bytes();
    let mut idx = 0;
    while idx < raw.len() {
        let b = raw[idx];
        if b == b'%' {
            if idx + 2 >= raw.len() {
                return None;
            }
            let hi = (raw[idx + 1] as char).to_digit(16)?;
            let lo = (raw[idx + 2] as char).to_digit(16)?;
            cleaned.push(((hi << 4) | lo) as u8);
            idx += 3;
        } else if !b.is_ascii_whitespace() {
            cleaned.push(b);
            idx += 1;
        } else {
            idx += 1;
        }
    }
    if cleaned.is_empty() || !cleaned.len().is_multiple_of(4) {
        return None;
    }

    fn val(b: u8) -> Option<u8> {
        match b {
            b'A'..=b'Z' => Some(b - b'A'),
            b'a'..=b'z' => Some(b - b'a' + 26),
            b'0'..=b'9' => Some(b - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }

    let mut out = Vec::with_capacity(cleaned.len() / 4 * 3);
    for (chunk_idx, chunk) in cleaned.chunks_exact(4).enumerate() {
        let is_last = (chunk_idx + 1) * 4 == cleaned.len();
        let a = val(chunk[0])?;
        let b = val(chunk[1])?;
        out.push((a << 2) | (b >> 4));

        if chunk[2] == b'=' {
            if !is_last || chunk[3] != b'=' {
                return None;
            }
            break;
        }
        let c = val(chunk[2])?;
        out.push((b << 4) | (c >> 2));

        if chunk[3] == b'=' {
            if !is_last {
                return None;
            }
            break;
        }
        let d = val(chunk[3])?;
        out.push((c << 6) | d);
    }
    Some(out)
}

/// 从 HLS 清单文本提取 Widevine PSSH；无 Widevine 密钥行时返回 `Ok(None)`，格式非法返回 `Err`。
pub fn widevine_pssh_from_hls(manifest: &str) -> Result<Option<Vec<u8>>, String> {
    let mut selected: Option<Vec<u8>> = None;
    for raw in manifest.lines() {
        let line = raw.trim();
        let Some(rest) = line.strip_prefix("#EXT-X-KEY:") else {
            continue;
        };
        let attributes = parse_ext_x_key_attributes(rest)?;
        let Some(format) = attributes.get("KEYFORMAT") else {
            continue;
        };
        if format != KEY_FORMAT_UUID && format != KEY_FORMAT_ALPHA {
            continue;
        }
        let uri = attributes
            .get("URI")
            .ok_or_else(|| INVALID_ERR.to_string())?;
        if uri.len() > 48 * 1024 {
            return Err(INVALID_ERR.to_string());
        }
        let bytes = decode_base64_data_uri(uri)?;
        if bytes.len() < 32 || bytes.len() > 32 * 1024 {
            return Err(INVALID_ERR.to_string());
        }
        let total_len = u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) as usize;
        if total_len != bytes.len()
            || &bytes[4..8] != b"pssh"
            || bytes[8] > 1
            || bytes[9] != 0
            || bytes[10] != 0
            || bytes[11] != 0
            || bytes[12..28] != WIDEVINE_UUID
        {
            return Err(INVALID_ERR.to_string());
        }
        let mut offset = 28usize;
        if bytes[8] == 1 {
            let kid_count =
                u32::from_be_bytes([bytes[28], bytes[29], bytes[30], bytes[31]]) as usize;
            offset = kid_count
                .checked_mul(16)
                .and_then(|n| n.checked_add(32))
                .ok_or_else(|| INVALID_ERR.to_string())?;
        }
        if offset.checked_add(4).is_none_or(|end| end > bytes.len()) {
            return Err(INVALID_ERR.to_string());
        }
        let data_len = u32::from_be_bytes([
            bytes[offset],
            bytes[offset + 1],
            bytes[offset + 2],
            bytes[offset + 3],
        ]) as usize;
        if data_len != bytes.len() - offset - 4 {
            return Err(INVALID_ERR.to_string());
        }
        if let Some(prev) = &selected {
            if prev != &bytes {
                return Err("HLS key rotation is not supported".to_string());
            }
        } else {
            selected = Some(bytes);
        }
    }
    Ok(selected)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn encode_base64(bytes: &[u8]) -> String {
        const TABLE: &[u8; 64] =
            b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut out = String::new();
        for chunk in bytes.chunks(3) {
            let b0 = chunk[0];
            let b1 = if chunk.len() > 1 { chunk[1] } else { 0 };
            let b2 = if chunk.len() > 2 { chunk[2] } else { 0 };
            out.push(TABLE[(b0 >> 2) as usize] as char);
            out.push(TABLE[(((b0 & 0x03) << 4) | (b1 >> 4)) as usize] as char);
            if chunk.len() > 1 {
                out.push(TABLE[(((b1 & 0x0f) << 2) | (b2 >> 6)) as usize] as char);
            } else {
                out.push('=');
            }
            if chunk.len() > 2 {
                out.push(TABLE[(b2 & 0x3f) as usize] as char);
            } else {
                out.push('=');
            }
        }
        out
    }

    fn make_pssh(marker: u8, version1: bool) -> Vec<u8> {
        let mut bytes = vec![0, 0, 0, 0];
        bytes.extend_from_slice(b"pssh");
        bytes.push(if version1 { 1 } else { 0 });
        bytes.extend_from_slice(&[0, 0, 0]);
        bytes.extend_from_slice(&WIDEVINE_UUID);
        if version1 {
            bytes.extend_from_slice(&[0, 0, 0, 1]);
            bytes.extend_from_slice(&[0u8; 16]);
        }
        bytes.extend_from_slice(&[0, 0, 0, 1, marker]);
        let len = (bytes.len() as u32).to_be_bytes();
        bytes[0..4].copy_from_slice(&len);
        bytes
    }

    fn make_key_line(bytes: &[u8], uri: Option<&str>, format: Option<&str>) -> String {
        let default_uri = format!(
            "data:application/octet-stream;base64,{}",
            encode_base64(bytes)
        );
        let u = uri.unwrap_or(&default_uri);
        let f = format.unwrap_or(KEY_FORMAT_UUID);
        format!("#EXT-X-KEY:METHOD=SAMPLE-AES-CTR,URI=\"{u}\",KEYFORMAT=\"{f}\"")
    }

    #[test]
    fn keeps_pssh_for_both_versions() {
        for v1 in [false, true] {
            let b = make_pssh(1, v1);
            let m = format!("#EXTM3U\r\n{}\r\n", make_key_line(&b, None, None));
            assert_eq!(widevine_pssh_from_hls(&m).unwrap().as_ref(), Some(&b));
            let m2 = make_key_line(&b, None, Some(KEY_FORMAT_ALPHA));
            assert_eq!(widevine_pssh_from_hls(&m2).unwrap().as_ref(), Some(&b));
        }
    }

    #[test]
    fn rejects_invalid_and_key_rotation() {
        let b1 = make_pssh(1, false);
        let b2 = make_pssh(2, false);
        let k1 = make_key_line(&b1, None, None);
        let k2 = make_key_line(&b2, None, None);
        assert_eq!(
            widevine_pssh_from_hls(&format!("{k1}\n{k1}"))
                .unwrap()
                .as_ref(),
            Some(&b1)
        );
        assert!(widevine_pssh_from_hls(&format!("{k1}\n{k2}")).is_err());
        assert!(
            widevine_pssh_from_hls(&make_key_line(&b1, Some("https://example.com/k"), None))
                .is_err()
        );
    }
}
