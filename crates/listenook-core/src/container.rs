use std::io::{Read, Seek, SeekFrom, Write};

use matroska_demuxer::{Frame, MatroskaFile, TrackEntry, TrackType};
use mp4::{
    AacConfig, AudioObjectType, AvcConfig, ChannelConfig, MediaConfig, Mp4Config, Mp4Sample, Mp4Writer,
    SampleFreqIndex, TrackConfig,
};

const VIDEO_TIMESCALE: u64 = 90_000;
const AVC: &str = "V_MPEG4/ISO/AVC";
const AAC: &str = "A_AAC";

fn parameter_sets(record: &[u8]) -> Option<(Vec<u8>, Vec<u8>)> {
    if record.len() < 7 || record[0] != 1 || record[4] & 3 != 3 || record[5] & 0x1f == 0 {
        return None;
    }
    let set = |at: usize| -> Option<(Vec<u8>, usize)> {
        let length = usize::from(u16::from_be_bytes([*record.get(at)?, *record.get(at + 1)?]));
        Some((record.get(at + 2..at + 2 + length)?.to_vec(), at + 2 + length))
    };
    let (sps, mut at) = set(6)?;
    for _ in 1..record[5] & 0x1f {
        at = set(at)?.1;
    }
    if *record.get(at)? == 0 {
        return None;
    }
    Some((sps, set(at + 1)?.0))
}

fn aac_config(private: &[u8]) -> Option<AacConfig> {
    let (first, second) = (*private.first()?, *private.get(1)?);
    let profile = AudioObjectType::try_from(first >> 3).ok()?;
    if profile != AudioObjectType::AacLowComplexity {
        return None;
    }
    Some(AacConfig {
        bitrate: 0,
        profile,
        freq_index: SampleFreqIndex::try_from(((first & 7) << 1) | (second >> 7)).ok()?,
        chan_conf: ChannelConfig::try_from((second >> 3) & 0xf).ok()?,
    })
}

struct Plan<'a> {
    video: &'a TrackEntry,
    audio: Option<&'a TrackEntry>,
}

fn plan(tracks: &[TrackEntry]) -> Result<Plan<'_>, &'static str> {
    let first = |kind: TrackType| tracks.iter().find(|track| track.track_type() == kind);
    let video = first(TrackType::Video).ok_or("no video track")?;
    let audio = first(TrackType::Audio);
    if video.codec_id() != AVC || audio.is_some_and(|audio| audio.codec_id() != AAC) {
        return Err("codecs an MP4 file written here cannot hold");
    }
    if video.content_encodings().is_some() || audio.is_some_and(|audio| audio.content_encodings().is_some()) {
        return Err("compressed or encrypted tracks");
    }
    Ok(Plan { video, audio })
}

pub fn mkv_fits_mp4<R: Read + Seek>(input: R) -> bool {
    MatroskaFile::open(input).is_ok_and(|file| {
        plan(file.tracks()).is_ok_and(|plan| {
            plan.video.codec_private().and_then(parameter_sets).is_some()
                && plan.audio.is_none_or(|audio| audio.codec_private().and_then(aac_config).is_some())
        })
    })
}

fn is_sync(data: &[u8]) -> bool {
    let mut at = 0;
    while at + 5 <= data.len() {
        let length = u32::from_be_bytes([data[at], data[at + 1], data[at + 2], data[at + 3]]) as usize;
        if data[at + 4] & 0x1f == 5 {
            return true;
        }
        at += 4 + length;
    }
    false
}

pub fn mkv_to_mp4<R: Read + Seek, W: Write + Seek>(
    mut open: impl FnMut() -> std::io::Result<R>,
    output: W,
) -> Result<(), String> {
    let fail = |error: &dyn std::fmt::Display| error.to_string();
    let mut file = MatroskaFile::open(open().map_err(|e| fail(&e))?).map_err(|e| fail(&e))?;
    let scale = file.info().timestamp_scale().get();
    let found = plan(file.tracks())?;
    let (video_number, audio_number) =
        (found.video.track_number().get(), found.audio.map(|audio| audio.track_number().get()));
    let (sps, pps) = found.video.codec_private().and_then(parameter_sets).ok_or("an unusual H.264 record")?;
    let picture = found.video.video().ok_or("no picture size")?;
    let (width, height) = (picture.pixel_width().get() as u16, picture.pixel_height().get() as u16);
    let audio = match found.audio {
        Some(track) => {
            let config = track.codec_private().and_then(aac_config).ok_or("AAC other than AAC-LC")?;
            let rate = track.audio().map_or(48_000.0, |audio| audio.sampling_frequency()) as u64;
            Some((config, rate.max(1)))
        }
        None => None,
    };

    let ticks = |timestamp: u64, per_second: u64| {
        (u128::from(timestamp) * u128::from(scale) * u128::from(per_second) / 1_000_000_000) as u64
    };
    let (mut shown, mut heard) = (Vec::<u64>::new(), Vec::<u64>::new());
    let mut frame = Frame::default();
    while file.next_frame(&mut frame).map_err(|e| fail(&e))? {
        if frame.track == video_number {
            shown.push(ticks(frame.timestamp, VIDEO_TIMESCALE));
        } else if Some(frame.track) == audio_number {
            heard.push(ticks(frame.timestamp, audio.as_ref().map_or(1, |(_, rate)| *rate)));
        }
    }
    if shown.is_empty() {
        return Err("no pictures".into());
    }
    let mut decoded = shown.clone();
    decoded.sort_unstable();
    let wait = decoded.iter().zip(&shown).map(|(decode, show)| decode.saturating_sub(*show)).max().unwrap_or(0);
    let length = |times: &[u64], index: usize, usual: u64| -> u32 {
        times.get(index + 1).map_or(usual, |next| next.saturating_sub(times[index])).clamp(1, u64::from(u32::MAX))
            as u32
    };
    let usual_picture = decoded.get(1).map_or(3000, |second| second - decoded[0]).max(1);

    let brand = |name: &str| name.parse().expect("a four-character code");
    let config = Mp4Config {
        major_brand: brand("isom"),
        minor_version: 512,
        compatible_brands: vec![brand("isom"), brand("iso2"), brand("avc1"), brand("mp41")],
        timescale: 1000,
    };
    let mut writer = Mp4Writer::write_start(output, &config).map_err(|e| fail(&e))?;
    writer
        .add_track(&TrackConfig {
            track_type: mp4::TrackType::Video,
            timescale: VIDEO_TIMESCALE as u32,
            language: "und".into(),
            media_conf: MediaConfig::AvcConfig(AvcConfig { width, height, seq_param_set: sps, pic_param_set: pps }),
        })
        .map_err(|e| fail(&e))?;
    if let Some((config, rate)) = &audio {
        writer
            .add_track(&TrackConfig {
                track_type: mp4::TrackType::Audio,
                timescale: *rate as u32,
                language: "und".into(),
                media_conf: MediaConfig::AacConfig(config.clone()),
            })
            .map_err(|e| fail(&e))?;
    }

    let mut file = MatroskaFile::open(open().map_err(|e| fail(&e))?).map_err(|e| fail(&e))?;
    let (mut picture, mut sound) = (0, 0);
    while file.next_frame(&mut frame).map_err(|e| fail(&e))? {
        let data = std::mem::take(&mut frame.data);
        if frame.track == video_number && picture < shown.len() {
            let sample = Mp4Sample {
                start_time: decoded[picture],
                duration: length(&decoded, picture, usual_picture),
                rendering_offset: (shown[picture] + wait - decoded[picture]) as i32,
                is_sync: frame.is_keyframe.unwrap_or_else(|| is_sync(&data)),
                bytes: data.into(),
            };
            writer.write_sample(1, &sample).map_err(|e| fail(&e))?;
            picture += 1;
        } else if Some(frame.track) == audio_number && sound < heard.len() {
            let sample = Mp4Sample {
                start_time: heard[sound],
                duration: length(&heard, sound, 1024),
                rendering_offset: 0,
                is_sync: true,
                bytes: data.into(),
            };
            writer.write_sample(2, &sample).map_err(|e| fail(&e))?;
            sound += 1;
        }
    }
    writer.write_end().map_err(|e| fail(&e))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AviSound {
    Mp3,
    Wav,
}

impl AviSound {
    pub fn extension(self) -> &'static str {
        match self {
            AviSound::Mp3 => "mp3",
            AviSound::Wav => "wav",
        }
    }
}

struct Avi<'a, R, W> {
    input: &'a mut R,
    output: &'a mut W,
    sound: Option<(usize, Vec<u8>)>,
    streams: usize,
    stream_is_sound: bool,
    written: u64,
}

impl<R: Read + Seek, W: Write + Seek> Avi<'_, R, W> {
    fn walk(&mut self, end: u64, depth: u8) -> std::io::Result<()> {
        if depth > 8 {
            return Ok(());
        }
        loop {
            let at = self.input.stream_position()?;
            let mut header = [0_u8; 8];
            if at + 8 > end || self.input.read_exact(&mut header).is_err() {
                return Ok(());
            }
            let size = u64::from(u32::from_le_bytes([header[4], header[5], header[6], header[7]]));
            let next = (at + 8 + size + (size & 1)).min(end.max(at + 8));
            match &header[..4] {
                b"RIFF" | b"LIST" => {
                    let mut kind = [0_u8; 4];
                    self.input.read_exact(&mut kind)?;
                    if matches!(&kind, b"AVI " | b"AVIX" | b"hdrl" | b"strl" | b"movi" | b"rec ") {
                        self.walk(next, depth + 1)?;
                    }
                    if &kind == b"strl" {
                        self.streams += 1;
                    }
                }
                b"strh" => {
                    let mut kind = [0_u8; 4];
                    self.input.read_exact(&mut kind)?;
                    self.stream_is_sound = &kind == b"auds";
                }
                b"strf" if self.stream_is_sound && self.sound.is_none() => {
                    let mut format = vec![0_u8; size.min(64) as usize];
                    self.input.read_exact(&mut format)?;
                    if format.len() >= 16 {
                        self.output.write_all(&[0_u8; 44])?;
                        self.sound = Some((self.streams, format));
                    }
                }
                [tens, ones, b'w', b'b'] if tens.is_ascii_digit() && ones.is_ascii_digit() => {
                    let stream = usize::from(tens - b'0') * 10 + usize::from(ones - b'0');
                    if self.sound.as_ref().is_some_and(|(number, _)| *number == stream) {
                        self.written += std::io::copy(&mut self.input.by_ref().take(size), self.output)?;
                    }
                }
                _ => {}
            }
            self.input.seek(SeekFrom::Start(next))?;
        }
    }
}

pub fn avi_sound<R: Read + Seek, W: Write + Seek>(mut input: R, mut output: W) -> Result<AviSound, String> {
    let fail = |error: std::io::Error| error.to_string();
    let end = input.seek(SeekFrom::End(0)).map_err(fail)?;
    input.seek(SeekFrom::Start(0)).map_err(fail)?;
    let mut avi =
        Avi { input: &mut input, output: &mut output, sound: None, streams: 0, stream_is_sound: false, written: 0 };
    avi.walk(end, 0).map_err(fail)?;
    let (written, Some((_, format))) = (avi.written, avi.sound.take()) else {
        return Err("no sound track".into());
    };
    if written == 0 {
        return Err("an empty sound track".into());
    }
    match u16::from_le_bytes([format[0], format[1]]) {
        0x55 => {
            let mut tag = [0_u8; 44];
            tag[..3].copy_from_slice(b"ID3");
            tag[3] = 3;
            tag[9] = 34;
            output.seek(SeekFrom::Start(0)).map_err(fail)?;
            output.write_all(&tag).map_err(fail)?;
            Ok(AviSound::Mp3)
        }
        1 => {
            let mut header = Vec::with_capacity(44);
            header.extend_from_slice(b"RIFF");
            header.extend_from_slice(&(36 + written as u32).to_le_bytes());
            header.extend_from_slice(b"WAVEfmt ");
            header.extend_from_slice(&16_u32.to_le_bytes());
            header.extend_from_slice(&format[..16]);
            header.extend_from_slice(b"data");
            header.extend_from_slice(&(written as u32).to_le_bytes());
            output.seek(SeekFrom::Start(0)).map_err(fail)?;
            output.write_all(&header).map_err(fail)?;
            Ok(AviSound::Wav)
        }
        other => Err(format!("sound format {other:#x}")),
    }
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use super::*;

    fn chunk(name: &[u8; 4], body: &[u8]) -> Vec<u8> {
        let mut out = name.to_vec();
        out.extend_from_slice(&(body.len() as u32).to_le_bytes());
        out.extend_from_slice(body);
        if body.len() % 2 == 1 {
            out.push(0);
        }
        out
    }

    fn list(kind: &[u8; 4], name: &[u8; 4], parts: &[Vec<u8>]) -> Vec<u8> {
        let mut body = name.to_vec();
        body.extend(parts.iter().flatten());
        chunk(kind, &body)
    }

    fn avi(format_tag: u16) -> Vec<u8> {
        let mut format = format_tag.to_le_bytes().to_vec();
        format.extend_from_slice(&[1, 0, 0x40, 0x1f, 0, 0, 0x80, 0x3e, 0, 0, 2, 0, 16, 0]);
        let video = list(b"LIST", b"strl", &[chunk(b"strh", b"vids____"), chunk(b"strf", &[0; 40])]);
        let sound = list(b"LIST", b"strl", &[chunk(b"strh", b"auds____"), chunk(b"strf", &format)]);
        let movie = list(
            b"LIST",
            b"movi",
            &[
                chunk(b"00dc", b"picture"),
                chunk(b"01wb", b"abc"),
                list(b"LIST", b"rec ", &[chunk(b"00dc", b"p2"), chunk(b"01wb", b"de")]),
            ],
        );
        list(b"RIFF", b"AVI ", &[list(b"LIST", b"hdrl", &[video, sound]), movie])
    }

    #[test]
    fn an_avi_files_mp3_sound_is_taken_out_whole() {
        let mut out = Cursor::new(Vec::new());
        assert_eq!(avi_sound(Cursor::new(avi(0x55)), &mut out), Ok(AviSound::Mp3));
        let bytes = out.into_inner();
        assert_eq!(&bytes[..3], b"ID3");
        assert_eq!(&bytes[44..], b"abcde", "only the sound track's chunks, in order");
    }

    #[test]
    fn an_avi_files_pcm_sound_becomes_a_wav_file() {
        let mut out = Cursor::new(Vec::new());
        assert_eq!(avi_sound(Cursor::new(avi(1)), &mut out), Ok(AviSound::Wav));
        let bytes = out.into_inner();
        assert_eq!(&bytes[..4], b"RIFF");
        assert_eq!(u32::from_le_bytes([bytes[40], bytes[41], bytes[42], bytes[43]]), 5);
        assert_eq!(u32::from_le_bytes([bytes[24], bytes[25], bytes[26], bytes[27]]), 8000, "the track's own rate");
        assert_eq!(&bytes[44..], b"abcde");
    }

    #[test]
    fn other_avi_sound_is_refused() {
        assert!(avi_sound(Cursor::new(avi(0x2000)), Cursor::new(Vec::new())).is_err());
        assert!(avi_sound(Cursor::new(b"not an avi file".to_vec()), Cursor::new(Vec::new())).is_err());
    }

    #[test]
    fn h264_and_aac_records_are_read() {
        let record = [1, 100, 0, 31, 0xff, 0xe1, 0, 2, 0x67, 0x64, 1, 0, 3, 0x68, 0xee, 0x3c];
        assert_eq!(parameter_sets(&record), Some((vec![0x67, 0x64], vec![0x68, 0xee, 0x3c])));
        assert!(parameter_sets(&[1, 100, 0, 31, 0xfd, 0xe1, 0, 0]).is_none(), "two-byte lengths are refused");
        let config = aac_config(&[0x12, 0x10]).unwrap();
        assert_eq!((config.freq_index, config.chan_conf), (SampleFreqIndex::Freq44100, ChannelConfig::Stereo));
        assert!(aac_config(&[0x2b, 0x92]).is_none(), "HE-AAC is refused");
        assert!(is_sync(&[0, 0, 0, 1, 0x65]) && !is_sync(&[0, 0, 0, 1, 0x41]));
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct SubtitleTrack {
    pub label: String,
    pub cues: Vec<crate::subtitles::Cue>,
}

fn ass_text(line: &str) -> String {
    let text = line.splitn(9, ',').nth(8).unwrap_or(line);
    let mut out = String::new();
    let mut styling = false;
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '{' => styling = true,
            '}' => styling = false,
            '\\' if !styling && matches!(chars.peek(), Some('N' | 'n')) => {
                chars.next();
                out.push('\n');
            }
            '\\' if !styling && chars.peek() == Some(&'h') => {
                chars.next();
                out.push(' ');
            }
            c if !styling => out.push(c),
            _ => {}
        }
    }
    out
}

fn label_of(name: Option<&str>, language: Option<&str>, number: usize) -> String {
    name.filter(|name| !name.trim().is_empty())
        .or(language.filter(|language| !language.is_empty() && *language != "und"))
        .map_or_else(|| format!("Track {number}"), str::to_owned)
}

pub fn mkv_subtitles<R: Read + Seek>(input: R) -> Vec<SubtitleTrack> {
    let Ok(mut file) = MatroskaFile::open(input) else {
        return Vec::new();
    };
    let scale = file.info().timestamp_scale().get();
    let milliseconds = |ticks: u64| (u128::from(ticks) * u128::from(scale) / 1_000_000) as i64;
    let mut tracks: Vec<(u64, bool, SubtitleTrack)> = file
        .tracks()
        .iter()
        .filter(|track| track.track_type() == TrackType::Subtitle && track.content_encodings().is_none())
        .filter(|track| matches!(track.codec_id(), "S_TEXT/UTF8" | "S_TEXT/ASS" | "S_TEXT/SSA" | "S_TEXT/WEBVTT"))
        .enumerate()
        .map(|(index, track)| {
            let label = label_of(track.name(), track.language_bcp47().or(track.language()), index + 1);
            let ass = matches!(track.codec_id(), "S_TEXT/ASS" | "S_TEXT/SSA");
            (track.track_number().get(), ass, SubtitleTrack { label, cues: Vec::new() })
        })
        .collect();
    if tracks.is_empty() {
        return Vec::new();
    }
    let mut frame = Frame::default();
    while let Ok(true) = file.next_frame(&mut frame) {
        let Some((_, ass, track)) = tracks.iter_mut().find(|(number, ..)| *number == frame.track) else {
            continue;
        };
        let raw = String::from_utf8_lossy(&frame.data);
        let text = crate::subtitles::clean_caption(&if *ass { ass_text(&raw) } else { raw.into_owned() }, true);
        let start_ms = milliseconds(frame.timestamp);
        let end_ms = start_ms + frame.duration.map_or(4000, milliseconds).max(1);
        if !text.trim().is_empty() {
            track.cues.push(crate::subtitles::Cue { start_ms, end_ms, text });
        }
    }
    tracks.into_iter().map(|(.., track)| track).filter(|track| !track.cues.is_empty()).collect()
}

pub fn mp4_subtitles<R: Read + Seek>(input: R, size: u64) -> Vec<SubtitleTrack> {
    let Ok(mut file) = mp4::Mp4Reader::read_header(input, size) else {
        return Vec::new();
    };
    let mut wanted: Vec<(u32, u64, String)> = file
        .tracks()
        .iter()
        .filter(|(_, track)| matches!(track.track_type(), Ok(mp4::TrackType::Subtitle)))
        .map(|(id, track)| (*id, u64::from(track.timescale().max(1)), track.language().to_owned()))
        .collect();
    wanted.sort();
    let mut out = Vec::new();
    for (index, (id, timescale, language)) in wanted.into_iter().enumerate() {
        let mut cues = Vec::new();
        for sample in 1..=file.sample_count(id).unwrap_or(0) {
            let Ok(Some(sample)) = file.read_sample(id, sample) else {
                continue;
            };
            let bytes = &sample.bytes;
            let length = bytes.get(..2).map_or(0, |size| usize::from(u16::from_be_bytes([size[0], size[1]])));
            let text = bytes.get(2..2 + length).map(String::from_utf8_lossy).unwrap_or_default();
            let text = crate::subtitles::clean_caption(&text, true);
            if text.trim().is_empty() {
                continue;
            }
            let start_ms = (sample.start_time * 1000 / timescale) as i64;
            let end_ms = ((sample.start_time + u64::from(sample.duration)) * 1000 / timescale) as i64;
            cues.push(crate::subtitles::Cue { start_ms, end_ms: end_ms.max(start_ms + 1), text });
        }
        if !cues.is_empty() {
            out.push(SubtitleTrack { label: label_of(None, Some(&language), index + 1), cues });
        }
    }
    out
}

#[cfg(test)]
mod subtitle_tests {
    use super::*;

    #[test]
    fn ass_events_lose_their_fields_and_styling() {
        assert_eq!(ass_text("1,0,Default,,0,0,0,,{\\i1}Hello,{\\i0} there\\Nfriend"), "Hello, there\nfriend");
        assert_eq!(label_of(Some("English (SDH)"), Some("en"), 1), "English (SDH)");
        assert_eq!(label_of(None, Some("und"), 2), "Track 2");
    }
}
