//! Repackages an AVI file's H.264 pictures and MP3 sound as a QuickTime movie, which Apple's
//! player can open (it opens no AVI), without decoding either.

use std::io::{Read, Seek, SeekFrom, Write};

use super::h264::{self, Order};
use super::movie::{Brand, MOVIE_TIMESCALE, Movie, Track, boxed, picture_entry, put16, put32};

#[derive(Default)]
struct Stream {
    kind: [u8; 4],
    scale: u32,
    rate: u32,
    format: Vec<u8>,
}

struct Chunk {
    stream: usize,
    at: u64,
    size: u32,
}

#[derive(Default)]
struct Layout {
    streams: Vec<Stream>,
    chunks: Vec<Chunk>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Scan {
    /// The headers and the first picture: enough to tell whether the file can be repackaged.
    FirstPicture,
    Whole,
}

fn le32(bytes: &[u8], at: usize) -> u32 {
    bytes.get(at..at + 4).map_or(0, |b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
}

fn le16(bytes: &[u8], at: usize) -> u16 {
    bytes.get(at..at + 2).map_or(0, |b| u16::from_le_bytes([b[0], b[1]]))
}

impl Layout {
    fn read<R: Read + Seek>(input: &mut R, scan: Scan) -> std::io::Result<Layout> {
        let end = input.seek(SeekFrom::End(0))?;
        input.seek(SeekFrom::Start(0))?;
        let mut layout = Layout::default();
        layout.walk(input, end, 0, scan)?;
        Ok(layout)
    }

    fn done(&self, scan: Scan) -> bool {
        scan == Scan::FirstPicture
            && self.chunks.iter().any(|chunk| {
                chunk.size > 0 && self.streams.get(chunk.stream).is_some_and(|stream| &stream.kind == b"vids")
            })
    }

    fn walk<R: Read + Seek>(&mut self, input: &mut R, end: u64, depth: u8, scan: Scan) -> std::io::Result<()> {
        if depth > 8 {
            return Ok(());
        }
        loop {
            if self.done(scan) {
                return Ok(());
            }
            let at = input.stream_position()?;
            let mut header = [0_u8; 8];
            if at + 8 > end || input.read_exact(&mut header).is_err() {
                return Ok(());
            }
            let size = u64::from(le32(&header, 4));
            let next = (at + 8 + size + (size & 1)).min(end.max(at + 8));
            match &header[..4] {
                b"RIFF" | b"LIST" => {
                    let mut kind = [0_u8; 4];
                    input.read_exact(&mut kind)?;
                    if &kind == b"strl" {
                        self.streams.push(Stream::default());
                    }
                    if matches!(&kind, b"AVI " | b"AVIX" | b"hdrl" | b"strl" | b"movi" | b"rec ") {
                        self.walk(input, next, depth + 1, scan)?;
                    }
                }
                b"strh" => {
                    let mut body = [0_u8; 32];
                    input.read_exact(&mut body[..size.min(32) as usize])?;
                    if let Some(stream) = self.streams.last_mut() {
                        stream.kind.copy_from_slice(&body[..4]);
                        (stream.scale, stream.rate) = (le32(&body, 20), le32(&body, 24));
                    }
                }
                b"strf" => {
                    let mut body = vec![0_u8; size.min(4096) as usize];
                    input.read_exact(&mut body)?;
                    if let Some(stream) = self.streams.last_mut() {
                        stream.format = body;
                    }
                }
                [tens, ones, a, b]
                    if tens.is_ascii_digit()
                        && ones.is_ascii_digit()
                        && matches!([*a, *b], [b'd', b'c'] | [b'd', b'b'] | [b'w', b'b']) =>
                {
                    let stream = usize::from(tens - b'0') * 10 + usize::from(ones - b'0');
                    self.chunks.push(Chunk { stream, at: at + 8, size: size.min(next - at - 8) as u32 });
                }
                _ => {}
            }
            input.seek(SeekFrom::Start(next))?;
        }
    }
}

const H264_CODES: [&[u8; 4]; 4] = [b"h264", b"x264", b"avc1", b"davc"];
const MP3: u16 = 0x55;

struct Plan {
    video: usize,
    audio: Option<usize>,
    width: u16,
    height: u16,
    scale: u32,
    rate: u32,
}

fn plan(layout: &Layout) -> Result<Plan, &'static str> {
    let first = |kind: &[u8; 4]| layout.streams.iter().position(|stream| &stream.kind == kind);
    let video = first(b"vids").ok_or("no video track")?;
    let stream = &layout.streams[video];
    let code = stream.format.get(16..20).map(<[u8]>::to_ascii_lowercase).unwrap_or_default();
    if !H264_CODES.iter().any(|known| known[..] == code[..]) {
        return Err("pictures other than H.264");
    }
    let audio = first(b"auds");
    if audio.is_some_and(|audio| le16(&layout.streams[audio].format, 0) != MP3) {
        return Err("sound other than MP3");
    }
    if stream.scale == 0 || stream.rate == 0 {
        return Err("no frame rate");
    }
    let width = le32(&stream.format, 4) as i32;
    let height = le32(&stream.format, 8) as i32;
    Ok(Plan {
        video,
        audio,
        width: width.unsigned_abs().min(u32::from(u16::MAX)) as u16,
        height: height.unsigned_abs().min(u32::from(u16::MAX)) as u16,
        scale: stream.scale,
        rate: stream.rate,
    })
}

/// Picture data that can be read: Annex B NAL units whose order of showing can be worked out.
fn readable(order: &mut Order, units: &[&[u8]]) -> Result<Option<(u32, i32)>, &'static str> {
    let mut place = None;
    for unit in units {
        match h264::kind(unit) {
            7 | 8 => order.parameters(unit),
            1 | 5 if place.is_none() => place = Some(order.picture(unit)?),
            _ => {}
        }
    }
    Ok(place)
}

/// Whether [`avi_to_mov`] can repackage this file: H.264 pictures, MP3 sound or none, and a
/// first picture whose order of showing can be read.
pub fn avi_fits_mov<R: Read + Seek>(mut input: R) -> bool {
    let Ok(layout) = Layout::read(&mut input, Scan::FirstPicture) else {
        return false;
    };
    let Ok(plan) = plan(&layout) else {
        return false;
    };
    let mut order = Order::default();
    let extra = layout.streams[plan.video].format.get(40..).unwrap_or_default();
    for unit in h264::nal_units(extra).unwrap_or_default() {
        order.parameters(unit);
    }
    let Some(chunk) = layout.chunks.iter().find(|chunk| chunk.stream == plan.video && chunk.size > 0) else {
        return false;
    };
    let mut data = vec![0; chunk.size as usize];
    if input.seek(SeekFrom::Start(chunk.at)).is_err() || input.read_exact(&mut data).is_err() {
        return false;
    }
    h264::nal_units(&data).is_some_and(|units| matches!(readable(&mut order, &units), Ok(Some(_))))
}

struct Picture {
    slot: u64,
    place: (u32, i32),
    sync: bool,
    size: u32,
    at: u64,
}

#[derive(Clone, Copy)]
struct Mp3Frame {
    length: usize,
    samples: u32,
    rate: u32,
    channels: u16,
    mpeg1: bool,
}

fn mp3_frame(header: &[u8]) -> Option<Mp3Frame> {
    let [a, b, c, d] = *header.get(..4)? else {
        return None;
    };
    if a != 0xff || b & 0xe0 != 0xe0 {
        return None;
    }
    let version = (b >> 3) & 3;
    if version == 1 || (b >> 1) & 3 != 1 {
        return None;
    }
    let mpeg1 = version == 3;
    const MPEG1: [u32; 15] = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320];
    const MPEG2: [u32; 15] = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160];
    let kilobits = *if mpeg1 { &MPEG1 } else { &MPEG2 }.get(usize::from(c >> 4))?;
    let base = *[44_100, 48_000, 32_000].get(usize::from((c >> 2) & 3))?;
    if kilobits == 0 {
        return None;
    }
    let rate = match version {
        3 => base,
        2 => base / 2,
        _ => base / 4,
    };
    let per_frame = if mpeg1 { 144_000 } else { 72_000 };
    Some(Mp3Frame {
        length: (per_frame * kilobits / rate + u32::from((c >> 1) & 1)) as usize,
        samples: if mpeg1 { 1152 } else { 576 },
        rate,
        channels: if d >> 6 == 3 { 1 } else { 2 },
        mpeg1,
    })
}

/// Cuts MP3 frames out of the sound's bytes, which AVI chunks need not split at frame edges.
#[derive(Default)]
struct Sound {
    pending: Vec<u8>,
    first: Option<Mp3Frame>,
    frames: Vec<(u64, u32)>,
}

impl Sound {
    fn take<W: Write + Seek>(&mut self, bytes: &[u8], movie: &mut Movie<W>) -> std::io::Result<()> {
        self.pending.extend_from_slice(bytes);
        let mut at = 0;
        while self.pending.len() - at >= 4 {
            let Some(frame) = mp3_frame(&self.pending[at..])
                .filter(|frame| self.first.is_none_or(|first| (first.rate, first.mpeg1) == (frame.rate, frame.mpeg1)))
            else {
                at += 1;
                continue;
            };
            if self.pending.len() - at < frame.length {
                break;
            }
            self.first.get_or_insert(frame);
            let start = movie.put(&self.pending[at..at + frame.length])?;
            self.frames.push((start, frame.length as u32));
            at += frame.length;
        }
        self.pending.drain(..at);
        Ok(())
    }

    /// The movie's sound track, made of the frames taken; none without a frame.
    fn track(&self) -> Option<Track> {
        let first = self.first.filter(|_| !self.frames.is_empty())?;
        let durations = vec![first.samples; self.frames.len()];
        let media: u64 = durations.iter().map(|duration| u64::from(*duration)).sum();
        Some(Track {
            sound: true,
            timescale: first.rate,
            entry: mp3_entry(first),
            durations,
            offsets: None,
            syncs: None,
            sizes: self.frames.iter().map(|frame| frame.1).collect(),
            chunks: self.frames.iter().map(|frame| frame.0).collect(),
            edits: vec![(media * MOVIE_TIMESCALE / u64::from(first.rate), 0)],
        })
    }
}

/// Repackages an AVI file with H.264 pictures and MP3 sound (or none) as a QuickTime movie.
pub fn avi_to_mov<R: Read + Seek, W: Write + Seek>(mut input: R, output: W) -> Result<(), String> {
    let fail = |error: std::io::Error| error.to_string();
    let layout = Layout::read(&mut input, Scan::Whole).map_err(fail)?;
    let plan = plan(&layout)?;
    let mut order = Order::default();
    let (mut sps, mut pps) = (None::<Vec<u8>>, None::<Vec<u8>>);
    let mut keep = |unit: &[u8], order: &mut Order| {
        match h264::kind(unit) {
            7 if sps.is_none() => sps = Some(unit.to_vec()),
            8 if pps.is_none() => pps = Some(unit.to_vec()),
            _ => {}
        }
        order.parameters(unit);
    };
    let extra = layout.streams[plan.video].format.get(40..).unwrap_or_default();
    for unit in h264::nal_units(extra).unwrap_or_default() {
        keep(unit, &mut order);
    }

    let mut movie = Movie::start(output, Brand::QuickTime).map_err(fail)?;

    let (mut pictures, mut sound) = (Vec::<Picture>::new(), Sound::default());
    let (mut slot, mut data, mut sample) = (0_u64, Vec::new(), Vec::new());
    for chunk in &layout.chunks {
        let video = chunk.stream == plan.video;
        if !video && Some(chunk.stream) != plan.audio {
            continue;
        }
        if chunk.size > 0 {
            data.resize(chunk.size as usize, 0);
            input.seek(SeekFrom::Start(chunk.at)).map_err(fail)?;
            input.read_exact(&mut data).map_err(fail)?;
        }
        if !video {
            sound.take(&data[..chunk.size as usize], &mut movie).map_err(fail)?;
            continue;
        }
        slot += 1;
        if chunk.size == 0 {
            continue;
        }
        let units = h264::nal_units(&data).ok_or("H.264 pictures without start codes")?;
        sample.clear();
        let mut place = None;
        for unit in &units {
            keep(unit, &mut order);
            if place.is_none() && matches!(h264::kind(unit), 1 | 5) {
                place = Some(order.picture(unit)?);
            }
            sample.extend_from_slice(&(unit.len() as u32).to_be_bytes());
            sample.extend_from_slice(unit);
        }
        let place = place.or(pictures.last().map(|picture| picture.place)).unwrap_or_default();
        let sync = units.iter().any(|unit| h264::kind(unit) == 5);
        let at = movie.put(&sample).map_err(fail)?;
        pictures.push(Picture { slot: slot - 1, place, sync, size: sample.len() as u32, at });
    }
    let (Some(sps), Some(pps)) = (sps, pps) else {
        return Err("no H.264 parameter sets".into());
    };
    if pictures.is_empty() {
        return Err("no pictures".into());
    }

    let mut tracks = vec![picture_track(&plan, &pictures, &sps, &pps)?];
    tracks.extend(sound.track());
    movie.finish(&tracks).map_err(fail)
}

fn picture_track(plan: &Plan, pictures: &[Picture], sps: &[u8], pps: &[u8]) -> Result<Track, String> {
    let mut shown: Vec<usize> = (0..pictures.len()).collect();
    shown.sort_by_key(|&index| (pictures[index].place, index));
    let mut shown_slot = vec![0; pictures.len()];
    for (rank, &index) in shown.iter().enumerate() {
        shown_slot[index] = pictures[rank].slot;
    }
    let wait = pictures.iter().zip(&shown_slot).map(|(picture, shown)| picture.slot.saturating_sub(*shown)).max();
    let wait = wait.unwrap_or(0);
    let tick = u64::from(plan.scale);
    let to_u32 = |value: u64| u32::try_from(value).map_err(|_| "a picture too long".to_owned());
    let durations = pictures
        .windows(2)
        .map(|pair| to_u32((pair[1].slot - pair[0].slot) * tick))
        .chain(std::iter::once(Ok(plan.scale)))
        .collect::<Result<Vec<_>, _>>()?;
    let offsets = pictures
        .iter()
        .zip(&shown_slot)
        .map(|(picture, shown)| to_u32((shown + wait - picture.slot) * tick))
        .collect::<Result<Vec<_>, _>>()?;
    let syncs: Vec<u32> = (1..).zip(pictures).filter(|(_, picture)| picture.sync).map(|(number, _)| number).collect();
    let movie = |ticks: u64| ticks * MOVIE_TIMESCALE / u64::from(plan.rate);
    let media: u64 = durations.iter().map(|duration| u64::from(*duration)).sum();
    // A picture is shown `wait` frames after its slot, as players reading the AVI itself show
    // it (a decoder holds pictures back that long to reorder them); keeping that delay keeps
    // the sound in step with the picture as it was in those players.
    let mut edits = Vec::new();
    if pictures[0].slot > 0 {
        edits.push((movie(pictures[0].slot * tick), -1));
    }
    edits.push((movie(media + wait * tick), 0));
    Ok(Track {
        sound: false,
        timescale: plan.rate,
        entry: avc1(plan.width, plan.height, sps, pps),
        durations,
        offsets: offsets.iter().any(|offset| *offset != 0).then_some(offsets),
        syncs: (syncs.len() < pictures.len()).then_some(syncs),
        sizes: pictures.iter().map(|picture| picture.size).collect(),
        chunks: pictures.iter().map(|picture| picture.at).collect(),
        edits,
    })
}

fn avc1(width: u16, height: u16, sps: &[u8], pps: &[u8]) -> Vec<u8> {
    picture_entry(b"avc1", width, height, |out| {
        boxed(out, b"avcC", |out| {
            out.push(1);
            out.extend_from_slice(sps.get(1..4).unwrap_or(&[0x64, 0, 0x1f]));
            out.extend_from_slice(&[0xff, 0xe1]);
            put16(out, sps.len() as u16);
            out.extend_from_slice(sps);
            out.push(1);
            put16(out, pps.len() as u16);
            out.extend_from_slice(pps);
            if sps.get(1).is_some_and(|profile| [100, 110, 122, 144].contains(profile)) {
                let parsed = h264::sps(sps).map(|(_, sps)| sps);
                let (chroma, luma_depth, chroma_depth) =
                    parsed.map_or((1, 0, 0), |sps| (sps.chroma_format, sps.luma_depth_minus8, sps.chroma_depth_minus8));
                out.extend_from_slice(&[0xfc | chroma, 0xf8 | luma_depth, 0xf8 | chroma_depth, 0]);
            }
        });
    })
}

/// A QuickTime sound description (version 1) for MP3: Apple's player drops MP3 described
/// the MP4 way (an `mp4a` entry with an MPEG-1 audio `esds`), but plays this one.
fn mp3_entry(frame: Mp3Frame) -> Vec<u8> {
    let mut out = Vec::new();
    boxed(&mut out, b".mp3", |out| {
        out.extend_from_slice(&[0; 6]);
        put16(out, 1);
        put16(out, 1);
        out.extend_from_slice(&[0; 6]);
        put16(out, frame.channels);
        put16(out, 16);
        put16(out, 0xfffe);
        put16(out, 0);
        put32(out, frame.rate << 16);
        put32(out, frame.samples);
        put32(out, 0);
        put32(out, 0);
        put32(out, 2);
    });
    out
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use super::*;

    #[test]
    fn mp3_frame_headers_are_read() {
        // MPEG-1 Layer III, 192 kbit/s, 48 kHz, joint stereo: 576-byte frames.
        let frame = mp3_frame(&[0xff, 0xfb, 0xb4, 0x44]).unwrap();
        assert_eq!((frame.length, frame.samples, frame.rate, frame.channels), (576, 1152, 48_000, 2));
        // MPEG-2 Layer III, 64 kbit/s, 24 kHz, mono, padded.
        let frame = mp3_frame(&[0xff, 0xf3, 0x86, 0xc4]).unwrap();
        assert_eq!((frame.length, frame.samples, frame.rate, frame.channels), (193, 576, 24_000, 1));
        assert!(mp3_frame(&[0xff, 0xfd, 0xb4, 0x44]).is_none(), "Layer II");
        assert!(mp3_frame(&[0xff, 0xfb, 0x04, 0x44]).is_none(), "free format");
    }

    #[test]
    fn mp3_frames_are_cut_across_chunks() {
        let mut frame = vec![0_u8; 576];
        frame[..4].copy_from_slice(&[0xff, 0xfb, 0xb4, 0x44]);
        let stream: Vec<u8> = [&[1, 2][..], &frame, &frame].concat();
        let mut sound = Sound::default();
        let mut movie = Movie::start(Cursor::new(Vec::new()), Brand::QuickTime).unwrap();
        let first = movie.put(&[]).unwrap();
        for piece in stream.chunks(500) {
            sound.take(piece, &mut movie).unwrap();
        }
        let frames = vec![(first, 576), (first + 576, 576)];
        assert_eq!(sound.frames, frames, "the two bytes before the first frame are dropped");
    }

    #[test]
    fn a_b_frame_avi_becomes_a_movie_shown_in_order() {
        let avi = include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/data/h264-mp3.avi"));
        assert!(avi_fits_mov(Cursor::new(&avi[..])));
        let mut out = Cursor::new(Vec::new());
        avi_to_mov(Cursor::new(&avi[..]), &mut out).unwrap();
        let bytes = out.into_inner();
        let size = bytes.len() as u64;
        let mut file = mp4::Mp4Reader::read_header(Cursor::new(bytes), size).unwrap();
        let mut ids: Vec<u32> = file.tracks().keys().copied().collect();
        ids.sort_unstable();
        assert_eq!(ids, [1, 2]);
        let pictures = file.sample_count(1).unwrap();
        assert_eq!(pictures, 20);
        let mut shown = Vec::new();
        for number in 1..=pictures {
            let sample = file.read_sample(1, number).unwrap().unwrap();
            assert_eq!(sample.is_sync, number == 1, "only the first picture is an IDR picture");
            shown.push(sample.start_time + u64::from(sample.rendering_offset as u32));
        }
        let decoded = shown.clone();
        shown.sort_unstable();
        shown.dedup();
        assert_eq!(shown.len(), 20, "every picture has a time of its own");
        assert_ne!(decoded, shown, "B-frames are shown in another order than decoded");
        assert!(file.sample_count(2).unwrap() > 10, "the MP3 frames");
    }

    #[test]
    fn other_avi_files_do_not_fit() {
        assert!(!avi_fits_mov(Cursor::new(b"not an avi file".to_vec())));
    }
}
