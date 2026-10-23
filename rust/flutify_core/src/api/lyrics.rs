use crate::lrc;
use crate::lyric_script::{self, LyricLang};

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

/// 短文本（曲名 / 歌手）文种识别，返回 `LyricLang.index`。
#[flutter_rust_bridge::frb(sync)]
pub fn detect_lyric_lang(text: String) -> i32 {
    lyric_script::detect_lang(&text).index()
}

/// 歌词正文主语言识别，返回 `LyricLang.index`。
#[flutter_rust_bridge::frb(sync)]
pub fn main_lyric_lang(text: String) -> i32 {
    lyric_script::lyric_lang(&text).index()
}

/// 歌词文字与目标语言的吻合度（0 ~ 100）。
#[flutter_rust_bridge::frb(sync)]
pub fn score_lyric_lang(target: i32, text: String) -> f64 {
    lyric_script::lang_score(LyricLang::from_index(target), &text)
}

/// 一行歌词的主导文字大类（0..=7，无字母时为 -1）。
#[flutter_rust_bridge::frb(sync)]
pub fn lyric_line_family(text: String) -> i32 {
    lyric_script::line_family(&text)
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
