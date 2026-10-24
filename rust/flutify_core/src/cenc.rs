//! 单轨分段 AAC/CENC (fMP4) 音频容器受限解析与清晰化补丁生成。
//!
//! 行为与 `lib/services/eme/cenc_audio.dart` 完全一致。

const WIDEVINE_UUID: [u8; 16] = [
    0xed, 0xef, 0x8b, 0xa9, 0x79, 0xd6, 0x4a, 0xce, 0xa3, 0xc8, 0x27, 0xdc, 0xd5, 0x1d, 0x21, 0xed,
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CencError {
    UnsupportedCodec,
    UnsupportedEncryptionScheme,
    Format(String),
}

impl CencError {
    pub fn to_wire_string(&self) -> String {
        match self {
            CencError::UnsupportedCodec => "UNSUPPORTED_CODEC".to_string(),
            CencError::UnsupportedEncryptionScheme => "UNSUPPORTED_ENCRYPTION_SCHEME".to_string(),
            CencError::Format(detail) => format!("CENC: {detail}"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CencSubsample {
    pub clear: u32,
    pub cipher: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CencSample {
    pub offset: usize,
    pub size: usize,
    pub kid: Vec<u8>,
    pub iv: Vec<u8>,
    pub subsamples: Vec<CencSubsample>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CencPatch {
    pub offset: usize,
    pub box_type: [u8; 4],
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CencParsed {
    pub pssh: Vec<u8>,
    pub samples: Vec<CencSample>,
    pub patches: Vec<CencPatch>,
}

#[derive(Clone, Copy)]
struct Mp4Box {
    box_type: [u8; 4],
    start: usize,
    body: usize,
    end: usize,
}

impl Mp4Box {
    fn type_str(&self) -> String {
        self.box_type.iter().map(|&b| b as char).collect()
    }
}

#[derive(Clone)]
struct EncryptionDesc {
    iv_size: usize,
    kid: Vec<u8>,
}

struct Cursor<'a> {
    bytes: &'a [u8],
    pos: usize,
    end: usize,
}

impl<'a> Cursor<'a> {
    fn new(bytes: &'a [u8], pos: usize, end: usize) -> Self {
        Self { bytes, pos, end }
    }

    fn need(&self, size: usize) -> Result<(), CencError> {
        if self.pos.checked_add(size).is_none_or(|p| p > self.end) {
            return Err(CencError::Format("truncated field".to_string()));
        }
        Ok(())
    }

    fn u16(&mut self) -> Result<u16, CencError> {
        self.need(2)?;
        let n = u16::from_be_bytes([self.bytes[self.pos], self.bytes[self.pos + 1]]);
        self.pos += 2;
        Ok(n)
    }

    fn u32(&mut self) -> Result<u32, CencError> {
        self.need(4)?;
        let n = u32::from_be_bytes([
            self.bytes[self.pos],
            self.bytes[self.pos + 1],
            self.bytes[self.pos + 2],
            self.bytes[self.pos + 3],
        ]);
        self.pos += 4;
        Ok(n)
    }

    fn i32(&mut self) -> Result<i32, CencError> {
        self.need(4)?;
        let n = i32::from_be_bytes([
            self.bytes[self.pos],
            self.bytes[self.pos + 1],
            self.bytes[self.pos + 2],
            self.bytes[self.pos + 3],
        ]);
        self.pos += 4;
        Ok(n)
    }

    fn u64(&mut self) -> Result<u64, CencError> {
        self.need(8)?;
        let n = u64::from_be_bytes([
            self.bytes[self.pos],
            self.bytes[self.pos + 1],
            self.bytes[self.pos + 2],
            self.bytes[self.pos + 3],
            self.bytes[self.pos + 4],
            self.bytes[self.pos + 5],
            self.bytes[self.pos + 6],
            self.bytes[self.pos + 7],
        ]);
        self.pos += 8;
        Ok(n)
    }

    fn blob(&mut self, size: usize) -> Result<Vec<u8>, CencError> {
        self.need(size)?;
        let b = self.bytes[self.pos..self.pos + size].to_vec();
        self.pos += size;
        Ok(b)
    }

    fn finish(&self) -> Result<(), CencError> {
        if self.pos != self.end {
            return Err(CencError::Format("extra field bytes".to_string()));
        }
        Ok(())
    }
}

fn read_u32(bytes: &[u8], at: usize) -> u32 {
    u32::from_be_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]])
}

fn read_u64(bytes: &[u8], at: usize) -> u64 {
    u64::from_be_bytes([
        bytes[at],
        bytes[at + 1],
        bytes[at + 2],
        bytes[at + 3],
        bytes[at + 4],
        bytes[at + 5],
        bytes[at + 6],
        bytes[at + 7],
    ])
}

fn read_type(bytes: &[u8], at: usize) -> [u8; 4] {
    [bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]]
}

fn parse_boxes(bytes: &[u8], start: usize, end: usize) -> Result<Vec<Mp4Box>, CencError> {
    let mut boxes = Vec::new();
    let mut at = start;
    while at < end {
        if end - at < 8 {
            return Err(CencError::Format("truncated box header".to_string()));
        }
        let size32 = read_u32(bytes, at) as usize;
        let mut header = 8usize;
        let size = if size32 == 1 {
            if end - at < 16 {
                return Err(CencError::Format("truncated extended box".to_string()));
            }
            header = 16;
            usize::try_from(read_u64(bytes, at + 8))
                .map_err(|_| CencError::Format("invalid box length".to_string()))?
        } else if size32 == 0 {
            end - at
        } else {
            size32
        };
        if size < header || size > end - at {
            return Err(CencError::Format("invalid box length".to_string()));
        }
        boxes.push(Mp4Box {
            box_type: read_type(bytes, at + 4),
            start: at,
            body: at + header,
            end: at + size,
        });
        at += size;
    }
    Ok(boxes)
}

fn children(bytes: &[u8], b: Mp4Box) -> Result<Vec<Mp4Box>, CencError> {
    parse_boxes(bytes, b.body, b.end)
}

fn one(boxes: &[Mp4Box], expected: &[u8; 4]) -> Result<Mp4Box, CencError> {
    let mut found = boxes.iter().copied().filter(|b| &b.box_type == expected);
    let first = found.next().ok_or_else(|| {
        let name: String = expected.iter().map(|&c| c as char).collect();
        CencError::Format(format!("expected one {name}"))
    })?;
    if found.next().is_some() {
        let name: String = expected.iter().map(|&c| c as char).collect();
        return Err(CencError::Format(format!("expected one {name}")));
    }
    Ok(first)
}

fn path_box(bytes: &[u8], mut current: Mp4Box, path: &[[u8; 4]]) -> Result<Mp4Box, CencError> {
    for step in path {
        let ch = children(bytes, current)?;
        current = one(&ch, step)?;
    }
    Ok(current)
}

fn min_body(b: Mp4Box, size: usize) -> Result<(), CencError> {
    if b.end - b.body < size {
        return Err(CencError::Format(format!("short {}", b.type_str())));
    }
    Ok(())
}

/// 解析 fMP4 / CENC 音频容器。
pub fn parse_cenc_audio(bytes: &[u8]) -> Result<CencParsed, CencError> {
    if bytes.len() > 64 * 1024 * 1024 {
        return Err(CencError::Format("experimental limit is 64 MiB".to_string()));
    }
    let mut patches = Vec::new();
    let top = parse_boxes(bytes, 0, bytes.len())?;
    let moov = one(&top, b"moov")?;
    let moov_children = children(bytes, moov)?;
    let trak = one(&moov_children, b"trak")?;
    let tkhd = path_box(bytes, trak, &[*b"tkhd"])?;
    min_body(tkhd, 24)?;
    let track_id = read_u32(
        bytes,
        tkhd.body + if bytes[tkhd.body] == 1 { 20 } else { 12 },
    );
    let hdlr = path_box(bytes, trak, &[*b"mdia", *b"hdlr"])?;
    min_body(hdlr, 12)?;
    if &read_type(bytes, hdlr.body + 8) != b"soun" {
        return Err(CencError::Format("expected audio track".to_string()));
    }
    let stsd = path_box(bytes, trak, &[*b"mdia", *b"minf", *b"stbl", *b"stsd"])?;
    min_body(stsd, 8)?;
    let entries = parse_boxes(bytes, stsd.body + 8, stsd.end)?;
    if entries.len() != read_u32(bytes, stsd.body + 4) as usize {
        return Err(CencError::Format("sample description count".to_string()));
    }
    let mut descriptions: Vec<Option<EncryptionDesc>> = Vec::with_capacity(entries.len());
    for entry in entries {
        if &entry.box_type == b"mp4a" {
            descriptions.push(None);
            continue;
        }
        if &entry.box_type != b"enca" {
            return Err(CencError::Format("unsupported audio codec".to_string()));
        }
        min_body(entry, 28)?;
        if bytes[entry.body + 8] != 0 || bytes[entry.body + 9] != 0 {
            return Err(CencError::Format(
                "unsupported audio sample entry version".to_string(),
            ));
        }
        let sinf = one(&parse_boxes(bytes, entry.body + 28, entry.end)?, b"sinf")?;
        let frma = path_box(bytes, sinf, &[*b"frma"])?;
        let schm = path_box(bytes, sinf, &[*b"schm"])?;
        min_body(frma, 4)?;
        min_body(schm, 8)?;
        if &read_type(bytes, frma.body) != b"mp4a" {
            return Err(CencError::UnsupportedCodec);
        }
        if &read_type(bytes, schm.body + 4) != b"cenc" {
            return Err(CencError::UnsupportedEncryptionScheme);
        }
        let tenc = path_box(bytes, sinf, &[*b"schi", *b"tenc"])?;
        min_body(tenc, 24)?;
        if bytes[tenc.body] != 0 || bytes[tenc.body + 6] != 1 {
            return Err(CencError::Format(
                "unsupported tenc version or protection".to_string(),
            ));
        }
        let iv_size = bytes[tenc.body + 7] as usize;
        if iv_size != 8 && iv_size != 16 {
            return Err(CencError::Format("unsupported IV size".to_string()));
        }
        descriptions.push(Some(EncryptionDesc {
            iv_size,
            kid: bytes[tenc.body + 8..tenc.body + 24].to_vec(),
        }));
        patches.push(CencPatch {
            offset: entry.start + 4,
            box_type: *b"mp4a",
        });
        patches.push(CencPatch {
            offset: sinf.start + 4,
            box_type: *b"free",
        });
    }

    let trex = path_box(bytes, moov, &[*b"mvex", *b"trex"])?;
    min_body(trex, 24)?;
    if read_u32(bytes, trex.body + 4) != track_id {
        return Err(CencError::Format("trex track mismatch".to_string()));
    }
    let default_description = read_u32(bytes, trex.body + 8);
    let default_size = read_u32(bytes, trex.body + 16);

    let mut init_data: Option<Vec<u8>> = None;
    for b in top
        .iter()
        .chain(moov_children.iter())
        .copied()
        .filter(|b| &b.box_type == b"pssh")
    {
        min_body(b, 24)?;
        if bytes[b.body + 4..b.body + 20] == WIDEVINE_UUID {
            init_data = Some(bytes[b.start..b.end].to_vec());
        }
        patches.push(CencPatch {
            offset: b.start + 4,
            box_type: *b"free",
        });
    }
    let pssh = init_data.ok_or_else(|| CencError::Format("missing Widevine PSSH".to_string()))?;

    let mdats: Vec<Mp4Box> = top
        .iter()
        .copied()
        .filter(|b| &b.box_type == b"mdat")
        .collect();
    let mut previous_end: i64 = 0;
    let mut samples = Vec::new();

    for moof in top.iter().copied().filter(|b| &b.box_type == b"moof") {
        let traf = path_box(bytes, moof, &[*b"traf"])?;
        let traf_children = children(bytes, traf)?;
        for b in traf_children
            .iter()
            .copied()
            .filter(|b| &b.box_type == b"sgpd" || &b.box_type == b"sbgp")
        {
            min_body(b, 8)?;
            if &read_type(bytes, b.body + 4) == b"seig" {
                return Err(CencError::Format(
                    "key rotation is not supported".to_string(),
                ));
            }
        }
        let tfhd = one(&traf_children, b"tfhd")?;
        min_body(tfhd, 8)?;
        let flags = read_u32(bytes, tfhd.body) & 0x00ff_ffff;
        if read_u32(bytes, tfhd.body + 4) != track_id {
            return Err(CencError::Format("fragment track mismatch".to_string()));
        }
        if (flags & !0x03_003b) != 0 {
            return Err(CencError::Format("unsupported tfhd flags".to_string()));
        }
        let mut reader = Cursor::new(bytes, tfhd.body + 8, tfhd.end);
        let base: i64 = if (flags & 1) != 0 {
            reader.u64()? as i64
        } else {
            moof.start as i64
        };
        let description = if (flags & 2) != 0 {
            reader.u32()?
        } else {
            default_description
        };
        if description < 1 || (description as usize) > descriptions.len() {
            return Err(CencError::Format("invalid description index".to_string()));
        }
        let encryption = &descriptions[(description - 1) as usize];
        if (flags & 8) != 0 {
            reader.u32()?;
        }
        let sample_size = if (flags & 0x10) != 0 {
            reader.u32()?
        } else {
            default_size
        };
        if (flags & 0x20) != 0 {
            reader.u32()?;
        }

        let mut positions: Vec<(usize, usize)> = Vec::new();
        let mut next_offset: Option<i64> = None;
        for trun in traf_children
            .iter()
            .copied()
            .filter(|b| &b.box_type == b"trun")
        {
            min_body(trun, 8)?;
            let run_flags = read_u32(bytes, trun.body) & 0x00ff_ffff;
            if (run_flags & !0xf05) != 0 {
                return Err(CencError::Format("unsupported trun flags".to_string()));
            }
            let mut run = Cursor::new(bytes, trun.body + 4, trun.end);
            let count = run.u32()?;
            if count > 100_000 {
                return Err(CencError::Format("sample count exceeds limit".to_string()));
            }
            let run_offset = if (run_flags & 1) != 0 {
                Some(base + (run.i32()? as i64))
            } else {
                next_offset
            };
            let mut offset = run_offset
                .ok_or_else(|| CencError::Format("missing first data offset".to_string()))?;
            if (run_flags & 4) != 0 {
                run.u32()?;
            }
            for _ in 0..count {
                if (run_flags & 0x100) != 0 {
                    run.u32()?;
                }
                let size = if (run_flags & 0x200) != 0 {
                    run.u32()? as i64
                } else {
                    sample_size as i64
                };
                if (run_flags & 0x400) != 0 {
                    run.u32()?;
                }
                if (run_flags & 0x800) != 0 {
                    run.u32()?;
                }
                if size <= 0
                    || size > 1024 * 1024
                    || offset < previous_end
                    || !mdats
                        .iter()
                        .any(|m| offset >= m.body as i64 && offset + size <= m.end as i64)
                {
                    return Err(CencError::Format(
                        "sample lies outside mdat or overlaps".to_string(),
                    ));
                }
                positions.push((offset as usize, size as usize));
                offset += size;
                previous_end = offset;
            }
            next_offset = Some(offset);
            run.finish()?;
        }

        let sencs: Vec<Mp4Box> = traf_children
            .iter()
            .copied()
            .filter(|b| &b.box_type == b"senc")
            .collect();
        let Some(enc) = encryption else {
            if !sencs.is_empty() {
                return Err(CencError::Format("clear description with senc".to_string()));
            }
            continue;
        };
        if sencs.len() != 1 {
            return Err(CencError::Format("missing sample encryption".to_string()));
        }
        let senc = sencs[0];
        min_body(senc, 8)?;
        let senc_flags = read_u32(bytes, senc.body);
        if senc_flags != 0 && senc_flags != 2 {
            return Err(CencError::Format("unsupported senc flags".to_string()));
        }
        let mut aux = Cursor::new(bytes, senc.body + 4, senc.end);
        if aux.u32()? as usize != positions.len() {
            return Err(CencError::Format("senc sample count mismatch".to_string()));
        }
        for (pos_offset, pos_size) in positions {
            let iv = aux.blob(enc.iv_size)?;
            let mut subs = Vec::new();
            if (senc_flags & 2) != 0 {
                let sub_count = aux.u16()? as usize;
                let mut total = 0usize;
                for _ in 0..sub_count {
                    let clear = aux.u16()?;
                    let cipher = aux.u32()?;
                    total = total.saturating_add(clear as usize).saturating_add(cipher as usize);
                    subs.push(CencSubsample {
                        clear: clear as u32,
                        cipher,
                    });
                }
                if !subs.is_empty() && total != pos_size {
                    return Err(CencError::Format(
                        "subsample sizes do not cover sample".to_string(),
                    ));
                }
            }
            samples.push(CencSample {
                offset: pos_offset,
                size: pos_size,
                kid: enc.kid.clone(),
                iv,
                subsamples: subs,
            });
        }
        aux.finish()?;
        for b in traf_children.iter().copied().filter(|b| {
            &b.box_type == b"senc" || &b.box_type == b"saiz" || &b.box_type == b"saio"
        }) {
            patches.push(CencPatch {
                offset: b.start + 4,
                box_type: *b"free",
            });
        }
    }

    if samples.is_empty() {
        return Err(CencError::Format(
            "no encrypted samples to verify".to_string(),
        ));
    }

    Ok(CencParsed {
        pssh,
        samples,
        patches,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u32_be(n: u32) -> [u8; 4] {
        n.to_be_bytes()
    }

    fn make_box(box_type: &[u8; 4], data: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(8 + data.len());
        out.extend_from_slice(&u32_be((data.len() + 8) as u32));
        out.extend_from_slice(box_type);
        out.extend_from_slice(data);
        out
    }

    fn fixture(
        subsamples: bool,
        omit_senc: bool,
        senc_count: u32,
        scheme: &[u8; 4],
        codec: &[u8; 4],
    ) -> Vec<u8> {
        let kid: Vec<u8> = (0u8..16).collect();
        let mut tenc_body = vec![0, 0, 0, 0, 0, 0, 1, 8];
        tenc_body.extend_from_slice(&kid);
        let tenc = make_box(b"tenc", &tenc_body);

        let mut schm_body = Vec::new();
        schm_body.extend_from_slice(&u32_be(0));
        schm_body.extend_from_slice(scheme);
        schm_body.extend_from_slice(&u32_be(0x10000));

        let mut sinf_body = Vec::new();
        sinf_body.extend_from_slice(&make_box(b"frma", codec));
        sinf_body.extend_from_slice(&make_box(b"schm", &schm_body));
        sinf_body.extend_from_slice(&make_box(b"schi", &tenc));
        let sinf = make_box(b"sinf", &sinf_body);

        let mut enca_body = vec![0u8; 28];
        enca_body.extend_from_slice(&sinf);

        let mut stsd_body = Vec::new();
        stsd_body.extend_from_slice(&u32_be(0));
        stsd_body.extend_from_slice(&u32_be(2));
        stsd_body.extend_from_slice(&make_box(b"enca", &enca_body));
        stsd_body.extend_from_slice(&make_box(b"mp4a", &[0u8; 28]));
        let stsd = make_box(b"stsd", &stsd_body);

        let mut tkhd_body = Vec::new();
        for v in [0, 0, 0, 1, 0, 0] {
            tkhd_body.extend_from_slice(&u32_be(v));
        }
        let mut hdlr_body = Vec::new();
        hdlr_body.extend_from_slice(&u32_be(0));
        hdlr_body.extend_from_slice(&u32_be(0));
        hdlr_body.extend_from_slice(b"soun");

        let mut mdia_body = Vec::new();
        mdia_body.extend_from_slice(&make_box(b"hdlr", &hdlr_body));
        mdia_body.extend_from_slice(&make_box(b"minf", &make_box(b"stbl", &stsd)));

        let mut trak_body = Vec::new();
        trak_body.extend_from_slice(&make_box(b"tkhd", &tkhd_body));
        trak_body.extend_from_slice(&make_box(b"mdia", &mdia_body));

        let mut trex_body = Vec::new();
        for v in [0, 1, 1, 1024, 4, 0] {
            trex_body.extend_from_slice(&u32_be(v));
        }

        let mut pssh_body = Vec::new();
        pssh_body.extend_from_slice(&u32_be(0));
        pssh_body.extend_from_slice(&WIDEVINE_UUID);
        pssh_body.extend_from_slice(&u32_be(0));

        let mut moov_body = Vec::new();
        moov_body.extend_from_slice(&make_box(b"trak", &trak_body));
        moov_body.extend_from_slice(&make_box(b"mvex", &make_box(b"trex", &trex_body)));
        moov_body.extend_from_slice(&make_box(b"pssh", &pssh_body));
        let moov = make_box(b"moov", &moov_body);

        let fragment = |encrypted: bool| -> Vec<u8> {
            let mut tfhd_body = Vec::new();
            for v in [0x2001a, 1, if encrypted { 1 } else { 2 }, 1024, 4] {
                tfhd_body.extend_from_slice(&u32_be(v));
            }
            let tfhd = make_box(b"tfhd", &tfhd_body);

            let senc = if encrypted && !omit_senc {
                let mut sb = Vec::new();
                sb.extend_from_slice(&u32_be(if subsamples { 2 } else { 0 }));
                sb.extend_from_slice(&u32_be(senc_count));
                for i in 0..2u8 {
                    sb.extend_from_slice(&[i + 1; 8]);
                    if subsamples {
                        sb.extend_from_slice(&[0, 1, 0, 1]);
                        sb.extend_from_slice(&u32_be(3));
                    }
                }
                make_box(b"senc", &sb)
            } else {
                Vec::new()
            };

            let make_moof = |offset: u32| -> Vec<u8> {
                let mut trun_body = Vec::new();
                for v in [1, 2, offset] {
                    trun_body.extend_from_slice(&u32_be(v));
                }
                let mut traf_body = Vec::new();
                traf_body.extend_from_slice(&tfhd);
                traf_body.extend_from_slice(&make_box(b"trun", &trun_body));
                traf_body.extend_from_slice(&senc);
                make_box(b"moof", &make_box(b"traf", &traf_body))
            };
            let header_len = make_moof(0).len() as u32 + 8;
            let mut out = make_moof(header_len);
            out.extend_from_slice(&make_box(b"mdat", &[11, 12, 13, 14, 21, 22, 23, 24]));
            out
        };

        let mut all = moov;
        all.extend_from_slice(&fragment(false));
        all.extend_from_slice(&fragment(true));
        all
    }

    #[test]
    fn cbcs_and_unsupported_codec_are_distinguished() {
        let cbcs = fixture(false, false, 2, b"cbcs", b"mp4a");
        assert_eq!(
            parse_cenc_audio(&cbcs),
            Err(CencError::UnsupportedEncryptionScheme)
        );
        let opus = fixture(false, false, 2, b"cenc", b"Opus");
        assert_eq!(parse_cenc_audio(&opus), Err(CencError::UnsupportedCodec));
    }

    #[test]
    fn parses_samples_and_patches() {
        let bytes = fixture(true, false, 2, b"cenc", b"mp4a");
        let parsed = parse_cenc_audio(&bytes).unwrap();
        assert_eq!(parsed.samples.len(), 2);
        assert_eq!(parsed.samples[0].size, 4);
        assert_eq!(parsed.samples[0].iv, vec![1u8; 8]);
        assert_eq!(
            parsed.samples[0].subsamples,
            vec![CencSubsample {
                clear: 1,
                cipher: 3
            }]
        );
        let mut out = bytes.clone();
        for p in &parsed.patches {
            out[p.offset..p.offset + 4].copy_from_slice(&p.box_type);
        }
        assert!(!out.windows(4).any(|w| w == b"enca"));
        assert!(!out.windows(4).any(|w| w == b"senc"));
    }
}
