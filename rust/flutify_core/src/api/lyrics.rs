use crate::lrc;

/// 一行同步歌词（`start_time_ms` 为毫秒）。
pub struct LrcLine {
    pub start_time_ms: i64,
    pub words: String,
}

/// 解析 LRC 文本，语义与 Dart 版 `LrcParser.parse` 一致。
#[flutter_rust_bridge::frb(sync)]
pub fn parse_lrc(lrc: String) -> Vec<LrcLine> {
    lrc::parse_lrc(&lrc)
        .into_iter()
        .map(|l| LrcLine { start_time_ms: l.start_time_ms, words: l.words })
        .collect()
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
