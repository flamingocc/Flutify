//! LRC 逐行同步歌词解析：`[mm:ss.xx]歌词`，一行可带多个时间标签（副歌复用）。
//!
//! 没有时间标签的行（`[ar:…]` 等元信息、纯文本）忽略；结果按时间升序。
//! 空歌词行保留，表示间奏 / 停顿。

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LyricLine {
    pub start_time_ms: i64,
    pub words: String,
}

/// 在 `b[i..]` 处尝试匹配 `\[(\d+):(\d+(?:\.\d+)?)\]`，返回 (结束位置, 毫秒)。
fn match_tag(b: &[u8], i: usize) -> Option<(usize, i64)> {
    if b.get(i) != Some(&b'[') {
        return None;
    }
    let digits = |mut p: usize| {
        let s = p;
        while p < b.len() && b[p].is_ascii_digit() {
            p += 1;
        }
        (s, p)
    };
    let (ms, me) = digits(i + 1);
    if me == ms || b.get(me) != Some(&b':') {
        return None;
    }
    let (ss, mut se) = digits(me + 1);
    if se == ss {
        return None;
    }
    if b.get(se) == Some(&b'.') {
        let (fs, fe) = digits(se + 1);
        if fe > fs {
            se = fe;
        }
    }
    if b.get(se) != Some(&b']') {
        return None;
    }
    let minutes: i64 = std::str::from_utf8(&b[ms..me]).ok()?.parse().ok()?;
    let seconds: f64 = std::str::from_utf8(&b[ss..se]).ok()?.parse().ok()?;
    Some((se + 1, minutes.checked_mul(60_000)? + (seconds * 1000.0).round() as i64))
}

pub fn parse_lrc(lrc: &str) -> Vec<LyricLine> {
    let mut lines: Vec<LyricLine> = Vec::new();
    for raw in lrc.split('\n') {
        let line = raw.replace('\r', "");
        let b = line.as_bytes();
        let mut tags = Vec::new();
        let mut text = String::new();
        let (mut i, mut last) = (0usize, 0usize);
        while i < b.len() {
            if let Some((end, ms)) = match_tag(b, i) {
                text.push_str(&line[last..i]);
                tags.push(ms);
                i = end;
                last = end;
            } else {
                i += 1;
            }
        }
        if tags.is_empty() {
            continue;
        }
        text.push_str(&line[last..]);
        let text = text.trim().to_string();
        for ms in tags {
            lines.push(LyricLine { start_time_ms: ms, words: text.clone() });
        }
    }
    // 稳定排序：同一时间点的多行保持原有先后（译文对照行在原文之后）
    lines.sort_by_key(|l| l.start_time_ms);
    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pairs(v: &[LyricLine]) -> Vec<(i64, &str)> {
        v.iter().map(|l| (l.start_time_ms, l.words.as_str())).collect()
    }

    #[test]
    fn parses_tags_ignores_meta_and_sorts() {
        let l = parse_lrc("[ar:Someone]\n[00:02.50]second\r\n[00:01.00]first\nplain text\n[01:00]minute");
        assert_eq!(pairs(&l), vec![(1000, "first"), (2500, "second"), (60000, "minute")]);
    }

    #[test]
    fn multi_tag_expands_and_empty_line_kept() {
        let l = parse_lrc("[00:01.00][00:05.00]chorus\n[00:03.00]");
        assert_eq!(pairs(&l), vec![(1000, "chorus"), (3000, ""), (5000, "chorus")]);
    }

    #[test]
    fn same_timestamp_keeps_order() {
        let l = parse_lrc("[00:01.00]a\n[00:01.00]b");
        assert_eq!(pairs(&l), vec![(1000, "a"), (1000, "b")]);
    }

    #[test]
    fn empty_input() {
        assert!(parse_lrc("").is_empty());
    }

    #[test]
    fn tag_in_middle_and_cjk_text() {
        let l = parse_lrc("[00:10.5] 你好 [00:12.25]世界 ");
        assert_eq!(pairs(&l), vec![(10500, "你好 世界"), (12250, "你好 世界")]);
    }

    #[test]
    fn malformed_tags_are_text_not_tags() {
        assert!(parse_lrc("[00:xx]a\n[:12]b\n[00:12.]c").is_empty());
    }
}
