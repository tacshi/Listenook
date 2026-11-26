//! Repackages a Matroska (MKV or WebM) video as an MP4 file, for players that open no
//! Matroska file (Apple's): its pictures and sound as they are where the player can show and
//! play them, its AV1 pictures converted where it can't show them.

use std::io::{Read, Seek, Write};

use matroska_demuxer::{Frame, MatroskaFile, TrackEntry, TrackType};

use super::movie::{Brand, MOVIE_TIMESCALE, Movie, Track, boxed, full, picture_entry, put16, put32, sound_entry};

/// The codings of pictures an MP4 file made here holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Codec {
    H264,
    Hevc,
    Vp9,
    Av1,
}

/// What a device does with pictures besides showing H.264 and HEVC.
#[derive(Debug, Clone, Copy, Default)]
pub struct Device {
    pub shows_vp9: bool,
    pub shows_av1: bool,
    /// Whether AV1 pictures it can't show can be converted into pictures it can.
    pub converts_av1: bool,
}

/// What can be made of a Matroska video for a device.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Plan {
    /// An MP4 file with its pictures and sound as they are, made as fast as the file is read.
    Copy,
    /// An MP4 file with its sound as it is and its AV1 pictures converted, which takes minutes.
    ConvertAv1,
    /// An MP4 file with its sound alone: the device can't show its pictures.
    Sound,
    /// Nothing as it is: its sound has to be decoded.
    Decode,
}

/// What [`mkv_to_mp4`] does with the pictures.
pub enum Pictures<'a> {
    Copy,
    Convert(&'a mut dyn Converter),
    Leave,
}

/// Turns pictures a device can't show into pictures it can.
pub trait Converter {
    /// Takes the next picture, in the order they are stored, to be shown at `shown` (in ticks
    /// of [`PICTURE_TIMESCALE`]).
    fn convert(&mut self, data: &[u8], shown: u64) -> Result<(), String>;
    /// The pictures that came out since the last call, in the order they are decoded: all
    /// that are left once `last` is set.
    fn converted(&mut self, last: bool) -> Result<Vec<Converted>, String>;
    /// How the pictures that came out are coded, once one has.
    fn coding(&self) -> Option<Coding>;
}

/// A picture that came out of a [`Converter`].
pub struct Converted {
    pub data: Vec<u8>,
    pub shown: u64,
    pub sync: bool,
}

/// How a [`Converter`]'s pictures are coded: H.264 (with its `avcC` record) or HEVC (`hvcC`).
#[derive(Debug, Clone)]
pub struct Coding {
    pub codec: Codec,
    pub config: Vec<u8>,
    pub width: u16,
    pub height: u16,
}

/// The ticks per second picture times are counted in.
pub const PICTURE_TIMESCALE: u64 = 90_000;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Sound {
    Aac,
    Opus,
}

fn picture_codec(track: &TrackEntry) -> Option<Codec> {
    if track.content_encodings().is_some() {
        return None;
    }
    let private = track.codec_private().unwrap_or_default();
    match track.codec_id() {
        "V_MPEG4/ISO/AVC" if !private.is_empty() => Some(Codec::H264),
        "V_MPEGH/ISO/HEVC" if !private.is_empty() => Some(Codec::Hevc),
        "V_VP9" => Some(Codec::Vp9),
        "V_AV1" if private.len() >= 4 => Some(Codec::Av1),
        _ => None,
    }
}

fn sound_codec(track: &TrackEntry) -> Option<Sound> {
    if track.content_encodings().is_some() {
        return None;
    }
    let private = track.codec_private().unwrap_or_default();
    match track.codec_id() {
        "A_AAC" if private.len() >= 2 => Some(Sound::Aac),
        "A_OPUS" if private.len() >= 19 && private.starts_with(b"OpusHead") => Some(Sound::Opus),
        _ => None,
    }
}

fn first(tracks: &[TrackEntry], kind: TrackType) -> Option<&TrackEntry> {
    tracks.iter().find(|track| track.track_type() == kind)
}

pub fn plan<R: Read + Seek>(input: R, device: Device) -> Plan {
    let Ok(file) = MatroskaFile::open(input) else {
        return Plan::Decode;
    };
    let sound = first(file.tracks(), TrackType::Audio);
    if sound.is_some_and(|track| sound_codec(track).is_none()) {
        return Plan::Decode;
    }
    match first(file.tracks(), TrackType::Video).and_then(picture_codec) {
        Some(Codec::H264 | Codec::Hevc) => Plan::Copy,
        Some(Codec::Vp9) if device.shows_vp9 => Plan::Copy,
        Some(Codec::Av1) if device.shows_av1 => Plan::Copy,
        Some(Codec::Av1) if device.converts_av1 => Plan::ConvertAv1,
        _ if sound.is_some() => Plan::Sound,
        _ => Plan::Decode,
    }
}

/// The samples of a track as they are written: when each is shown, in the order they are
/// decoded, and where it is.
#[derive(Default)]
struct Samples {
    shown: Vec<u64>,
    at: Vec<u64>,
    sizes: Vec<u32>,
    syncs: Vec<bool>,
}

impl Samples {
    /// Adds a sample: a sync sample (one a player can start at) when `sync` says so, the
    /// first one alone where nothing tells.
    fn push(&mut self, shown: u64, at: u64, size: usize, sync: Option<bool>) {
        self.syncs.push(sync.unwrap_or(self.shown.is_empty()));
        self.shown.push(shown);
        self.at.push(at);
        self.sizes.push(size as u32);
    }

    /// The track the samples make, `usual` ticks long each where nothing else tells.
    fn track(self, sound: bool, timescale: u64, entry: Vec<u8>, usual: u64) -> Option<Track> {
        let mut decoded = self.shown.clone();
        decoded.sort_unstable();
        let start = *decoded.first()?;
        let wait = decoded.iter().zip(&self.shown).map(|(decode, show)| decode.saturating_sub(*show)).max()?;
        let usual = decoded.get(1).map_or(usual, |second| second - start);
        let clamp = |ticks: u64| ticks.clamp(1, u64::from(u32::MAX)) as u32;
        let durations: Vec<u32> = (0..decoded.len())
            .map(|index| clamp(decoded.get(index + 1).map_or(usual, |next| next - decoded[index])))
            .collect();
        let offsets: Vec<u32> =
            self.shown.iter().zip(&decoded).map(|(show, decode)| (show + wait - decode) as u32).collect();
        let syncs: Vec<u32> = (1..).zip(&self.syncs).filter(|(_, sync)| **sync).map(|(number, _)| number).collect();
        let media: u64 = durations.iter().map(|duration| u64::from(*duration)).sum();
        let movie = |ticks: u64| ticks * MOVIE_TIMESCALE / timescale;
        let mut edits = Vec::new();
        if start > 0 {
            edits.push((movie(start), -1));
        }
        edits.push((movie(media), wait as i64));
        Some(Track {
            sound,
            timescale: timescale as u32,
            entry,
            durations,
            offsets: offsets.iter().any(|offset| *offset != 0).then_some(offsets),
            syncs: (syncs.len() < self.syncs.len()).then_some(syncs),
            sizes: self.sizes,
            chunks: self.at,
            edits,
        })
    }
}

/// Repackages the Matroska video `input` as an MP4 file, doing what `pictures` says with its
/// pictures. `going` is told how far along it is, from 0 to 1, and stops it by answering false.
pub fn mkv_to_mp4<R: Read + Seek, W: Write + Seek>(
    input: R,
    output: W,
    mut pictures: Pictures,
    going: &mut dyn FnMut(f64) -> bool,
) -> Result<(), String> {
    let fail = |error: &dyn std::fmt::Display| error.to_string();
    let mut file = MatroskaFile::open(input).map_err(|e| fail(&e))?;
    let scale = file.info().timestamp_scale().get();
    let length = file.info().duration().unwrap_or(0.0);
    let picture = match pictures {
        Pictures::Leave => None,
        _ => {
            let track = first(file.tracks(), TrackType::Video).ok_or("no video track")?;
            let codec = picture_codec(track).ok_or("pictures an MP4 file made here cannot hold")?;
            let video = track.video().ok_or("no picture size")?;
            let size = |pixels: u64| pixels.min(u64::from(u16::MAX)) as u16;
            let (width, height) = (size(video.pixel_width().get()), size(video.pixel_height().get()));
            let private = track.codec_private().unwrap_or_default().to_vec();
            Some((track.track_number().get(), codec, width, height, private))
        }
    };
    let sound = match first(file.tracks(), TrackType::Audio) {
        Some(track) => {
            let coding = sound_codec(track).ok_or("sound an MP4 file made here cannot hold")?;
            let audio = track.audio().ok_or("no sound format")?;
            let rate = match coding {
                Sound::Opus => 48_000,
                Sound::Aac => (audio.sampling_frequency() as u64).max(1),
            };
            let channels = audio.channels().get().min(8) as u16;
            Some((
                track.track_number().get(),
                coding,
                rate,
                channels,
                track.codec_private().unwrap_or_default().to_vec(),
            ))
        }
        None => None,
    };
    if picture.is_none() && sound.is_none() {
        return Err("nothing to repackage".into());
    }

    let ticks = |timestamp: u64, per_second: u64| {
        (u128::from(timestamp) * u128::from(scale) * u128::from(per_second) / 1_000_000_000) as u64
    };
    let mut movie = Movie::start(output, Brand::Mp4).map_err(|e| fail(&e))?;
    let (mut shown, mut heard) = (Samples::default(), Samples::default());
    let mut vp9 = None;
    let mut frame = Frame::default();
    while file.next_frame(&mut frame).map_err(|e| fail(&e))? {
        if !going(if length > 0.0 { frame.timestamp as f64 / length } else { 0.0 }) {
            return Err("stopped".into());
        }
        let data = std::mem::take(&mut frame.data);
        if picture.as_ref().is_some_and(|(number, ..)| *number == frame.track) {
            let time = ticks(frame.timestamp, PICTURE_TIMESCALE);
            match &mut pictures {
                Pictures::Convert(converter) => {
                    converter.convert(&data, time)?;
                    for out in converter.converted(false)? {
                        let at = movie.put(&out.data).map_err(|e| fail(&e))?;
                        shown.push(out.shown, at, out.data.len(), Some(out.sync));
                    }
                }
                _ => {
                    if vp9.is_none() {
                        vp9 = vp9_header(&data);
                    }
                    let at = movie.put(&data).map_err(|e| fail(&e))?;
                    shown.push(time, at, data.len(), frame.is_keyframe);
                }
            }
        } else if let Some((_, _, rate, ..)) = sound.as_ref().filter(|(number, ..)| *number == frame.track) {
            let at = movie.put(&data).map_err(|e| fail(&e))?;
            heard.push(ticks(frame.timestamp, *rate), at, data.len(), Some(true));
        }
    }

    let mut tracks = Vec::new();
    if let Some((_, codec, width, height, private)) = &picture {
        let entry = match &mut pictures {
            Pictures::Convert(converter) => {
                for out in converter.converted(true)? {
                    let at = movie.put(&out.data).map_err(|e| fail(&e))?;
                    shown.push(out.shown, at, out.data.len(), Some(out.sync));
                }
                let coding = converter.coding().ok_or("no picture came out")?;
                description(coding.codec, coding.width, coding.height, &coding.config, None)?
            }
            _ => description(*codec, *width, *height, private, vp9)?,
        };
        tracks.push(shown.track(false, PICTURE_TIMESCALE, entry, PICTURE_TIMESCALE / 30).ok_or("no pictures")?);
    }
    if let Some((_, coding, rate, channels, private)) = &sound {
        let (entry, usual) = match coding {
            Sound::Aac => (sound_entry(b"mp4a", *channels, *rate as u32, |out| esds(out, private)), 1024),
            Sound::Opus => (sound_entry(b"Opus", *channels, 48_000, |out| dops(out, private)), 960),
        };
        tracks.extend(heard.track(true, *rate, entry, usual));
    }
    movie.finish(&tracks).map_err(|e| fail(&e))
}

/// The sample description of pictures: from their configuration record, or for VP9, which
/// Matroska keeps none of, from the header of its first key frame.
fn description(
    codec: Codec,
    width: u16,
    height: u16,
    record: &[u8],
    vp9: Option<Vp9Header>,
) -> Result<Vec<u8>, &'static str> {
    let holding = |kind: &[u8; 4], name: &[u8; 4]| {
        Ok(picture_entry(kind, width, height, |out| boxed(out, name, |out| out.extend_from_slice(record))))
    };
    match codec {
        Codec::H264 => holding(b"avc1", b"avcC"),
        Codec::Hevc => holding(b"hvc1", b"hvcC"),
        Codec::Av1 => holding(b"av01", b"av1C"),
        Codec::Vp9 => {
            let header = vp9.ok_or("no VP9 key frame")?;
            Ok(picture_entry(b"vp09", width, height, |out| vpcc(out, header, width, height)))
        }
    }
}

/// An MPEG-4 elementary stream descriptor for AAC, holding its AudioSpecificConfig.
fn esds(out: &mut Vec<u8>, config: &[u8]) {
    let descriptor = |out: &mut Vec<u8>, tag: u8, body: &[u8]| {
        out.extend_from_slice(&[tag, 0x80, 0x80, 0x80, body.len() as u8]);
        out.extend_from_slice(body);
    };
    let mut specific = Vec::new();
    descriptor(&mut specific, 5, config);
    let mut decoder = vec![0x40, 0x15, 0, 0, 0];
    decoder.extend_from_slice(&[0; 8]);
    decoder.extend_from_slice(&specific);
    let mut stream = vec![0, 0, 0];
    descriptor(&mut stream, 4, &decoder);
    descriptor(&mut stream, 6, &[2]);
    full(out, b"esds", 0, 0, |out| descriptor(out, 3, &stream));
}

/// The Opus specific box, from the Matroska track's `OpusHead` (little-endian fields where
/// the box's are big-endian).
fn dops(out: &mut Vec<u8>, head: &[u8]) {
    let le16 = |at: usize| u16::from_le_bytes([head[at], head[at + 1]]);
    boxed(out, b"dOps", |out| {
        out.push(0);
        out.push(head[9]);
        put16(out, le16(10));
        put32(out, u32::from_le_bytes([head[12], head[13], head[14], head[15]]));
        put16(out, le16(16));
        out.push(head[18]);
        if head[18] != 0 {
            out.extend_from_slice(head.get(19..21 + usize::from(head[9])).unwrap_or_default());
        }
    });
}

/// What a VP9 key frame's header says of its pictures.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Vp9Header {
    profile: u8,
    depth: u8,
    /// 1 for 4:2:0, 2 for 4:2:2, 3 for 4:4:4, as `vpcC` counts them.
    chroma: u8,
    full_range: bool,
    space: u8,
}

fn vp9_header(frame: &[u8]) -> Option<Vp9Header> {
    let mut at = 0_usize;
    let mut bits = |count: usize| -> Option<u32> {
        let mut value = 0;
        for _ in 0..count {
            let byte = *frame.get(at / 8)?;
            value = (value << 1) | u32::from((byte >> (7 - at % 8)) & 1);
            at += 1;
        }
        Some(value)
    };
    if bits(2)? != 2 {
        return None;
    }
    let low = bits(1)?;
    let profile = (bits(1)? << 1 | low) as u8;
    if profile == 3 {
        bits(1)?;
    }
    if bits(1)? == 1 || bits(1)? != 0 {
        return None;
    }
    bits(2)?;
    if bits(24)? != 0x49_8342 {
        return None;
    }
    let depth = if profile >= 2 { if bits(1)? == 1 { 12 } else { 10 } } else { 8 };
    let space = bits(3)? as u8;
    let odd = profile == 1 || profile == 3;
    let (full_range, chroma) = if space != 7 {
        let full_range = bits(1)? == 1;
        let chroma = if odd {
            match (bits(1)?, bits(1)?) {
                (1, 1) => 1,
                (1, 0) => 2,
                _ => 3,
            }
        } else {
            1
        };
        (full_range, chroma)
    } else {
        (true, 3)
    };
    Some(Vp9Header { profile, depth, chroma, full_range, space })
}

/// The VP9 configuration box, its level judged by the picture's size.
fn vpcc(out: &mut Vec<u8>, header: Vp9Header, width: u16, height: u16) {
    const LEVELS: [(u64, u8); 8] = [
        (36_864, 10),
        (73_728, 11),
        (122_880, 20),
        (245_760, 21),
        (552_960, 30),
        (983_040, 31),
        (2_228_224, 41),
        (8_912_896, 51),
    ];
    let pixels = u64::from(width) * u64::from(height);
    let level = LEVELS.iter().find(|(most, _)| pixels <= *most).map_or(61, |(_, level)| *level);
    // The colour space the header names, as primaries, transfer and matrix (ISO/IEC 23091-2).
    let colour = match header.space {
        1 | 3 => [6, 6, 6],
        4 => [7, 7, 7],
        5 => [9, 14, 9],
        7 => [1, 13, 0],
        _ => [1, 1, 1],
    };
    full(out, b"vpcC", 1, 0, |out| {
        out.push(header.profile);
        out.push(level);
        out.push(header.depth << 4 | header.chroma << 1 | u8::from(header.full_range));
        out.extend_from_slice(&colour);
        put16(out, 0);
    });
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use super::*;

    fn data(name: &str) -> &'static [u8] {
        match name {
            "av1" => include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/data/av1-opus.mkv")),
            "vp9" => include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/data/vp9-opus.webm")),
            "hevc" => include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/data/hevc-aac.mkv")),
            _ => include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/data/h264-aac.mkv")),
        }
    }

    /// The MP4 file made, and the kind of each track's sample description.
    fn repackage(name: &str, pictures: Pictures) -> (mp4::Mp4Reader<Cursor<Vec<u8>>>, Vec<String>) {
        let mut out = Cursor::new(Vec::new());
        mkv_to_mp4(Cursor::new(data(name)), &mut out, pictures, &mut |_| true).unwrap();
        let bytes = out.into_inner();
        let kinds = bytes
            .windows(4)
            .enumerate()
            .filter(|(_, name)| name == b"stsd")
            .map(|(at, _)| String::from_utf8_lossy(&bytes[at + 16..at + 20]).into_owned())
            .collect();
        let size = bytes.len() as u64;
        (mp4::Mp4Reader::read_header(Cursor::new(bytes), size).unwrap(), kinds)
    }

    #[test]
    fn what_is_made_depends_on_what_the_device_shows() {
        let plan_for = |name, device| plan(Cursor::new(data(name)), device);
        let none = Device::default();
        assert_eq!(plan_for("h264", none), Plan::Copy);
        assert_eq!(plan_for("hevc", none), Plan::Copy);
        assert_eq!(plan_for("vp9", none), Plan::Sound);
        assert_eq!(plan_for("vp9", Device { shows_vp9: true, ..none }), Plan::Copy);
        assert_eq!(plan_for("av1", none), Plan::Sound);
        assert_eq!(plan_for("av1", Device { converts_av1: true, ..none }), Plan::ConvertAv1);
        assert_eq!(plan_for("av1", Device { shows_av1: true, converts_av1: true, ..none }), Plan::Copy);
        assert_eq!(plan(Cursor::new(b"not a video".to_vec()), none), Plan::Decode);
    }

    #[test]
    fn pictures_and_sound_are_copied_as_they_are() {
        for (name, picture, sound) in
            [("h264", "avc1", "mp4a"), ("hevc", "hvc1", "mp4a"), ("vp9", "vp09", "Opus"), ("av1", "av01", "Opus")]
        {
            let (mut file, kinds) = repackage(name, Pictures::Copy);
            assert_eq!(kinds, [picture, sound], "{name}");
            let pictures = file.sample_count(1).unwrap();
            assert_eq!(pictures, 15, "{name}: a second at 15 pictures a second");
            let first = file.read_sample(1, 1).unwrap().unwrap();
            assert!(first.is_sync, "{name}: starts at a key frame");
            let mut times: Vec<u64> = (1..=pictures)
                .map(|number| {
                    let sample = file.read_sample(1, number).unwrap().unwrap();
                    sample.start_time + u64::from(sample.rendering_offset as u32)
                })
                .collect();
            times.sort_unstable();
            times.dedup();
            assert_eq!(times.len(), 15, "{name}: every picture has a time of its own");
            assert!(file.sample_count(2).unwrap() > 10, "{name}: the sound");
        }
    }

    #[test]
    fn left_pictures_leave_the_sound_alone() {
        let (file, kinds) = repackage("av1", Pictures::Leave);
        assert_eq!(kinds, ["Opus"]);
        assert_eq!(file.tracks()[&1].track_type().unwrap(), mp4::TrackType::Audio);
    }

    /// Converts each picture into its first byte, held back like an encoder that waits for a
    /// few pictures before giving any out.
    #[derive(Default)]
    struct Fake {
        held: Vec<Converted>,
        taken: usize,
    }

    impl Converter for Fake {
        fn convert(&mut self, data: &[u8], shown: u64) -> Result<(), String> {
            self.held.push(Converted { data: data[..1].to_vec(), shown, sync: self.taken == 0 });
            self.taken += 1;
            Ok(())
        }

        fn converted(&mut self, last: bool) -> Result<Vec<Converted>, String> {
            Ok(if last || self.held.len() > 3 { std::mem::take(&mut self.held) } else { Vec::new() })
        }

        fn coding(&self) -> Option<Coding> {
            Some(Coding { codec: Codec::Hevc, config: vec![1, 2, 3], width: 80, height: 46 })
        }
    }

    #[test]
    fn converted_pictures_take_the_place_of_the_stored_ones() {
        let mut fake = Fake::default();
        let (mut file, kinds) = repackage("av1", Pictures::Convert(&mut fake));
        assert_eq!(kinds, ["hvc1", "Opus"]);
        assert_eq!((file.tracks()[&1].width(), file.tracks()[&1].height()), (80, 46));
        assert_eq!(file.sample_count(1).unwrap(), 15);
        let sync: Vec<bool> = (1..=15).map(|n| file.read_sample(1, n).unwrap().unwrap().is_sync).collect();
        assert_eq!(sync.iter().filter(|sync| **sync).count(), 1);
    }

    #[test]
    fn stopping_stops_the_repackaging() {
        let mut calls = 0;
        let result = mkv_to_mp4(Cursor::new(data("av1")), Cursor::new(Vec::new()), Pictures::Copy, &mut |_| {
            calls += 1;
            calls < 3
        });
        assert_eq!(result, Err("stopped".into()));
    }

    #[test]
    fn vp9_key_frame_headers_are_read() {
        let mut file = MatroskaFile::open(Cursor::new(data("vp9"))).unwrap();
        let mut frame = Frame::default();
        while file.next_frame(&mut frame).unwrap() && frame.track != 1 {}
        let header = vp9_header(&frame.data).unwrap();
        assert_eq!((header.profile, header.depth, header.chroma), (0, 8, 1));
        assert!(vp9_header(&[0x80, 0, 0]).is_none(), "an inter frame");
    }

    #[test]
    fn opus_heads_become_opus_specific_boxes() {
        let head = b"OpusHead\x01\x02\x38\x01\x80\xbb\x00\x00\x00\x00\x00";
        let mut out = Vec::new();
        dops(&mut out, head);
        assert_eq!(&out[4..8], b"dOps");
        assert_eq!(&out[8..], &[0, 2, 0x01, 0x38, 0, 0, 0xbb, 0x80, 0, 0, 0]);
    }
}
