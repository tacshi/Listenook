use std::{
    fs::File,
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
};

use matroska_demuxer::{Frame, MatroskaFile, TrackType};

use crate::media::subtitles;

/// The subtitles of the video at `video`: each file beside it named after it, then each track
/// inside it.
pub fn subtitle_tracks(video: &str) -> Vec<SubtitleTrack> {
    let files = crate::media::subtitles::paired(video, &[]).into_iter().filter_map(|path| {
        let cues = crate::media::subtitles::read_cues(&path)?;
        let label = Path::new(&path).file_name().and_then(|name| name.to_str()).unwrap_or(&path).to_owned();
        Some(SubtitleTrack { id: format!("file:{path}"), label, cues })
    });
    let inside = subtitles_in(Path::new(video)).into_iter().enumerate();
    files.chain(inside.map(|(index, track)| SubtitleTrack { id: format!("embedded:{index}"), ..track })).collect()
}

/// The subtitle tracks inside the video at `path`.
pub fn subtitles_in(path: &Path) -> Vec<SubtitleTrack> {
    let Ok(file) = File::open(path) else {
        return Vec::new();
    };
    match crate::media::subtitles::extension(&path.to_string_lossy()).as_str() {
        "mkv" | "webm" => mkv_subtitles(file),
        "mp4" | "m4v" | "mov" => match file.metadata() {
            Ok(metadata) => mp4_subtitles(file, metadata.len()),
            Err(_) => Vec::new(),
        },
        _ => Vec::new(),
    }
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

/// Writes the sound of the AVI file `source` beside `stem`, in the format it comes in: the
/// file it wrote, or why it could not.
pub fn avi_sound_file(source: &Path, stem: &Path) -> Result<PathBuf, String> {
    let part = stem.with_extension("part");
    let opened = File::open(source).and_then(|input| Ok((input, File::create(&part)?)));
    let written = opened.map_err(|error| error.to_string()).and_then(|(input, output)| avi_sound(input, output));
    let renamed = written.and_then(|kind| {
        let path = stem.with_extension(kind.extension());
        std::fs::rename(&part, &path).map(|()| path).map_err(|error| error.to_string())
    });
    if renamed.is_err() {
        let _ = std::fs::remove_file(&part);
    }
    renamed
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
}

#[derive(Debug, Clone, PartialEq)]
pub struct SubtitleTrack {
    /// What it is told apart by: `file:` and the file's path, or `embedded:` and its number
    /// among the video's own.
    pub id: String,
    pub label: String,
    pub cues: Vec<crate::media::subtitles::Cue>,
}

/// The text of an ASS line as a Matroska frame holds it: the ninth of its fields, after its
/// order, layer, style, name, margins and effect.
fn ass_frame_text(frame: &str) -> String {
    subtitles::ass_text(frame.splitn(9, ',').nth(8).unwrap_or(frame))
}

fn label_of(name: Option<&str>, language: Option<&str>, number: usize) -> String {
    name.filter(|name| !name.trim().is_empty())
        .or(language.filter(|language| !language.is_empty() && *language != "und"))
        .map_or_else(|| format!("Track {number}"), str::to_owned)
}

fn mkv_subtitles<R: Read + Seek>(input: R) -> Vec<SubtitleTrack> {
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
            (track.track_number().get(), ass, SubtitleTrack { id: String::new(), label, cues: Vec::new() })
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
        let text = subtitles::plain(&if *ass { ass_frame_text(&raw) } else { raw.into_owned() });
        let start_ms = milliseconds(frame.timestamp);
        let end_ms = start_ms + frame.duration.map_or(4000, milliseconds).max(1);
        if !text.trim().is_empty() {
            track.cues.push(subtitles::Cue { start_ms, end_ms, text });
        }
    }
    tracks
        .into_iter()
        .map(|(_, ass, mut track)| {
            if ass {
                track.cues = subtitles::together(track.cues);
            }
            track
        })
        .filter(|track| !track.cues.is_empty())
        .collect()
}

/// How many seconds at the start of an MP4's first audio track its edit list
/// leaves out: the encoder's priming, which players skip (2112 samples from
/// Apple's encoders, none in many others). `None` without an audio track or
/// an edit list.
pub fn mp4_audio_skip<R: Read + Seek>(input: R, size: u64) -> Option<f64> {
    let file = mp4::Mp4Reader::read_header(input, size).ok()?;
    let (_, track) = file
        .tracks()
        .iter()
        .filter(|(_, track)| matches!(track.track_type(), Ok(mp4::TrackType::Audio)))
        .min_by_key(|(id, _)| **id)?;
    let edits = &track.trak.edts.as_ref()?.elst.as_ref()?.entries;
    // An empty edit (media time -1) only delays the track.
    let edit = edits.iter().find(|edit| edit.media_time != u64::MAX && edit.media_time != u64::from(u32::MAX))?;
    Some(edit.media_time as f64 / f64::from(track.timescale().max(1)))
}

fn mp4_subtitles<R: Read + Seek>(input: R, size: u64) -> Vec<SubtitleTrack> {
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
            let text = crate::media::subtitles::clean_caption(&text, true);
            if text.trim().is_empty() {
                continue;
            }
            let start_ms = (sample.start_time * 1000 / timescale) as i64;
            let end_ms = ((sample.start_time + u64::from(sample.duration)) * 1000 / timescale) as i64;
            cues.push(crate::media::subtitles::Cue { start_ms, end_ms: end_ms.max(start_ms + 1), text });
        }
        if !cues.is_empty() {
            out.push(SubtitleTrack { id: String::new(), label: label_of(None, Some(&language), index + 1), cues });
        }
    }
    out
}

#[cfg(test)]
mod subtitle_tests {
    use super::*;

    #[test]
    fn ass_events_lose_their_fields_and_styling() {
        assert_eq!(ass_frame_text("1,0,Default,,0,0,0,,{\\i1}Hello,{\\i0} there\\Nfriend"), "Hello, there\nfriend");
        assert_eq!(label_of(Some("English (SDH)"), Some("en"), 1), "English (SDH)");
        assert_eq!(label_of(None, Some("und"), 2), "Track 2");
    }

    #[test]
    fn a_videos_subtitles_are_the_files_named_after_it() {
        let folder = std::env::temp_dir().join(format!("listenook-tracks-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        let file = |name: &str, text: &str| {
            let path = folder.join(name);
            std::fs::write(&path, text).unwrap();
            path.to_str().unwrap().to_owned()
        };
        let video = file("talk.mp4", "");
        let srt = file("talk.srt", "1\n00:00:01,000 --> 00:00:02,500\nHello <i>there</i>\n");
        let vtt = file("talk.en.vtt", "WEBVTT\n\n00:00:03.000 --> 00:00:04.000\nBye\n");
        file("other.srt", "1\n00:00:01,000 --> 00:00:02,000\nNo\n");
        let tracks = subtitle_tracks(&video);
        let found: Vec<(&str, &str, usize)> =
            tracks.iter().map(|track| (track.id.as_str(), track.label.as_str(), track.cues.len())).collect();
        assert_eq!(found, [(&*format!("file:{vtt}"), "talk.en.vtt", 1), (&*format!("file:{srt}"), "talk.srt", 1)]);
        assert_eq!((tracks[1].cues[0].start_ms, tracks[1].cues[0].text.as_str()), (1_000, "Hello there"));
        let _ = std::fs::remove_dir_all(&folder);
    }
}
