use crate::aes::{AesCipher, AesCtr};
use crate::audio_normalization::AudioNormalization;
use crate::spotify_id::SpotifyId;
use crate::web_totp;

/// 从 22 位 base62 ID 解析出 16 字节原始 GID。
#[flutter_rust_bridge::frb(sync)]
pub fn spotify_id_from_base62(src: String) -> Result<Vec<u8>, String> {
    Ok(SpotifyId::from_base62(&src)?.raw.to_vec())
}

/// 从 32 位十六进制 GID 解析出 16 字节原始 GID。
#[flutter_rust_bridge::frb(sync)]
pub fn spotify_id_from_base16(src: String) -> Result<Vec<u8>, String> {
    Ok(SpotifyId::from_base16(&src)?.raw.to_vec())
}

/// 从 `spotify:track:xxx` / `track:xxx` / `xxx` 提取 16 字节原始 GID。
#[flutter_rust_bridge::frb(sync)]
pub fn spotify_id_from_uri(uri: String) -> Result<Vec<u8>, String> {
    Ok(SpotifyId::from_uri(&uri)?.raw.to_vec())
}

/// 16 字节原始 GID 转 22 位 base62。
#[flutter_rust_bridge::frb(sync)]
pub fn spotify_id_to_base62(raw: Vec<u8>) -> Result<String, String> {
    Ok(SpotifyId::from_raw(&raw)?.to_base62())
}

/// 16 字节原始 GID 转 32 位小写十六进制。
#[flutter_rust_bridge::frb(sync)]
pub fn spotify_id_to_base16(raw: Vec<u8>) -> Result<String, String> {
    Ok(SpotifyId::from_raw(&raw)?.to_base16())
}

/// 音频响度均衡数据。
pub struct NormalizationInfo {
    pub track_gain_db: f64,
    pub track_peak: f64,
    pub volume_factor: f64,
}

/// 解析 16 字节 Spotify 音频响度头；不合法时返回 None。
#[flutter_rust_bridge::frb(sync)]
pub fn parse_audio_normalization(bytes: Vec<u8>) -> Option<NormalizationInfo> {
    let norm = AudioNormalization::parse(&bytes)?;
    Some(NormalizationInfo {
        track_gain_db: norm.track_gain_db,
        track_peak: norm.track_peak,
        volume_factor: norm.volume_factor(),
    })
}

/// 按增益与峰值计算播放器音量倍率（[0.0, 1.0]）。
#[flutter_rust_bridge::frb(sync)]
pub fn normalization_volume_factor(track_gain_db: f64, track_peak: f64) -> f64 {
    AudioNormalization::compute_volume_factor(track_gain_db, track_peak)
}

/// AES 单块（16 字节）加密。
#[flutter_rust_bridge::frb(sync)]
pub fn aes_encrypt_block(key: Vec<u8>, block: Vec<u8>) -> Result<Vec<u8>, String> {
    Ok(AesCipher::new(&key)?.encrypt_block(&block)?.to_vec())
}

/// AES-128-CTR 从指定字节偏移起加/解密一段数据。
#[flutter_rust_bridge::frb(sync)]
pub fn aes_ctr_process_at_offset(
    key: Vec<u8>,
    iv: Vec<u8>,
    offset: i64,
    mut data: Vec<u8>,
) -> Result<Vec<u8>, String> {
    if offset < 0 {
        return Err("offset must be >= 0".to_string());
    }
    let mut ctr = AesCtr::at_offset(&key, &iv, offset as usize)?;
    ctr.process(&mut data);
    Ok(data)
}

/// 还原混淆的 Web 播放器 TOTP secret。
#[flutter_rust_bridge::frb(sync)]
pub fn deobfuscate_totp_secret(obfuscated: String) -> Vec<u8> {
    web_totp::deobfuscate_secret(&obfuscated)
}

/// 生成标准 HMAC-SHA1 TOTP 口令。
#[flutter_rust_bridge::frb(sync)]
pub fn generate_totp(secret: Vec<u8>, timestamp_ms: i64, period: i64, digits: u32) -> String {
    web_totp::totp(&secret, timestamp_ms, period, digits)
}

/// 使用内置 V61 密钥直接生成指定毫秒时间戳的 6 位 Web 播放器 TOTP。
#[flutter_rust_bridge::frb(sync)]
pub fn generate_web_player_totp_v61(timestamp_ms: i64) -> String {
    web_totp::web_player_totp_v61(timestamp_ms)
}
