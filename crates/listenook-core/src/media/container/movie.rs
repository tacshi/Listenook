//! Writes MP4 files and QuickTime movies: each sample's bytes as they come, then the tables
//! that say where each one is and when it plays.

use std::io::{BufWriter, Seek, SeekFrom, Write};

/// The timescale of the movie as a whole, which edit lists and track lengths are counted in.
pub(super) const MOVIE_TIMESCALE: u64 = 1000;

#[derive(Clone, Copy)]
pub(super) enum Brand {
    /// A QuickTime movie, for sound descriptions only Apple's player reads (MP3 as `.mp3`).
    QuickTime,
    /// An MP4 file, which VP9, AV1 and Opus are only described for.
    Mp4,
}

pub(super) struct Movie<W: Write + Seek> {
    out: BufWriter<W>,
    mdat: u64,
    written: u64,
}

impl<W: Write + Seek> Movie<W> {
    pub(super) fn start(output: W, brand: Brand) -> std::io::Result<Self> {
        let mut out = BufWriter::new(output);
        let header = ftyp(brand);
        out.write_all(&header)?;
        let mdat = header.len() as u64;
        out.write_all(&[0, 0, 0, 1, b'm', b'd', b'a', b't', 0, 0, 0, 0, 0, 0, 0, 0])?;
        Ok(Movie { out, mdat, written: mdat + 16 })
    }

    /// Writes one sample's bytes: where in the file they start.
    pub(super) fn put(&mut self, bytes: &[u8]) -> std::io::Result<u64> {
        self.out.write_all(bytes)?;
        let at = self.written;
        self.written += bytes.len() as u64;
        Ok(at)
    }

    pub(super) fn finish(mut self, tracks: &[Track]) -> std::io::Result<()> {
        self.out.seek(SeekFrom::Start(self.mdat + 8))?;
        self.out.write_all(&(self.written - self.mdat).to_be_bytes())?;
        self.out.seek(SeekFrom::Start(self.written))?;
        self.out.write_all(&moov(tracks))?;
        self.out.flush()
    }
}

/// A track of the movie: how its samples are described, and where and when each one is.
pub(super) struct Track {
    pub(super) sound: bool,
    pub(super) timescale: u32,
    /// The sample description: a visual one starts with the picture's width and height.
    pub(super) entry: Vec<u8>,
    pub(super) durations: Vec<u32>,
    /// How long after it is decoded each sample is shown; none when each is shown at once.
    pub(super) offsets: Option<Vec<u32>>,
    /// The samples (counted from 1) a player can start at; none when it can start at any.
    pub(super) syncs: Option<Vec<u32>>,
    pub(super) sizes: Vec<u32>,
    pub(super) chunks: Vec<u64>,
    /// `(length in the movie's timescale, start in the track's media, or -1 for a gap)`.
    pub(super) edits: Vec<(u64, i64)>,
}

impl Track {
    fn media_length(&self) -> u64 {
        self.durations.iter().map(|duration| u64::from(*duration)).sum()
    }

    fn length(&self) -> u64 {
        self.edits.iter().map(|(length, _)| length).sum()
    }

    fn size(&self) -> (u16, u16) {
        let at = |offset: usize| self.entry.get(offset..offset + 2).map_or(0, |b| u16::from_be_bytes([b[0], b[1]]));
        if self.sound { (0, 0) } else { (at(32), at(34)) }
    }
}

pub(super) fn boxed(out: &mut Vec<u8>, name: &[u8; 4], body: impl FnOnce(&mut Vec<u8>)) {
    let start = out.len();
    out.extend_from_slice(&[0; 4]);
    out.extend_from_slice(name);
    body(out);
    let size = (out.len() - start) as u32;
    out[start..start + 4].copy_from_slice(&size.to_be_bytes());
}

pub(super) fn full(out: &mut Vec<u8>, name: &[u8; 4], version: u8, flags: u32, body: impl FnOnce(&mut Vec<u8>)) {
    boxed(out, name, |out| {
        out.extend_from_slice(&((u32::from(version) << 24) | flags).to_be_bytes());
        body(out);
    });
}

pub(super) fn put16(out: &mut Vec<u8>, value: u16) {
    out.extend_from_slice(&value.to_be_bytes());
}

pub(super) fn put32(out: &mut Vec<u8>, value: u32) {
    out.extend_from_slice(&value.to_be_bytes());
}

fn put64(out: &mut Vec<u8>, value: u64) {
    out.extend_from_slice(&value.to_be_bytes());
}

/// A visual sample description of the picture coding `kind`, with its configuration boxes.
pub(super) fn picture_entry(kind: &[u8; 4], width: u16, height: u16, boxes: impl FnOnce(&mut Vec<u8>)) -> Vec<u8> {
    let mut out = Vec::new();
    boxed(&mut out, kind, |out| {
        out.extend_from_slice(&[0; 6]);
        put16(out, 1);
        out.extend_from_slice(&[0; 16]);
        put16(out, width);
        put16(out, height);
        put32(out, 0x0048_0000);
        put32(out, 0x0048_0000);
        put32(out, 0);
        put16(out, 1);
        out.extend_from_slice(&[0; 32]);
        put16(out, 0x18);
        put16(out, 0xffff);
        boxes(out);
    });
    out
}

/// An MP4 sound description of the coding `kind`, with its configuration boxes.
pub(super) fn sound_entry(kind: &[u8; 4], channels: u16, rate: u32, boxes: impl FnOnce(&mut Vec<u8>)) -> Vec<u8> {
    let mut out = Vec::new();
    boxed(&mut out, kind, |out| {
        out.extend_from_slice(&[0; 6]);
        put16(out, 1);
        out.extend_from_slice(&[0; 8]);
        put16(out, channels);
        put16(out, 16);
        put32(out, 0);
        put32(out, rate.min(0xffff) << 16);
        boxes(out);
    });
    out
}

const MATRIX: [u32; 9] = [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000];

fn ftyp(brand: Brand) -> Vec<u8> {
    let mut out = Vec::new();
    boxed(&mut out, b"ftyp", |out| match brand {
        Brand::QuickTime => {
            out.extend_from_slice(b"qt  ");
            put32(out, 0x200);
            out.extend_from_slice(b"qt  ");
        }
        Brand::Mp4 => {
            out.extend_from_slice(b"isom");
            put32(out, 0x200);
            out.extend_from_slice(b"isomiso2iso6mp41");
        }
    });
    out
}

fn runs(values: &[u32]) -> Vec<(u32, u32)> {
    let mut out: Vec<(u32, u32)> = Vec::new();
    for &value in values {
        match out.last_mut() {
            Some((count, last)) if *last == value => *count += 1,
            _ => out.push((1, value)),
        }
    }
    out
}

fn moov(tracks: &[Track]) -> Vec<u8> {
    let mut out = Vec::new();
    let longest = tracks.iter().map(Track::length).max().unwrap_or(0);
    boxed(&mut out, b"moov", |out| {
        full(out, b"mvhd", 1, 0, |out| {
            put64(out, 0);
            put64(out, 0);
            put32(out, MOVIE_TIMESCALE as u32);
            put64(out, longest);
            put32(out, 0x0001_0000);
            put16(out, 0x0100);
            out.extend_from_slice(&[0; 10]);
            MATRIX.iter().for_each(|value| put32(out, *value));
            out.extend_from_slice(&[0; 24]);
            put32(out, tracks.len() as u32 + 1);
        });
        for (id, track) in (1..).zip(tracks) {
            write_track(out, id, track);
        }
    });
    out
}

fn write_track(out: &mut Vec<u8>, id: u32, track: &Track) {
    let (width, height) = track.size();
    boxed(out, b"trak", |out| {
        full(out, b"tkhd", 1, 3, |out| {
            put64(out, 0);
            put64(out, 0);
            put32(out, id);
            put32(out, 0);
            put64(out, track.length());
            out.extend_from_slice(&[0; 8]);
            put16(out, 0);
            put16(out, 0);
            put16(out, if track.sound { 0x0100 } else { 0 });
            put16(out, 0);
            MATRIX.iter().for_each(|value| put32(out, *value));
            put32(out, u32::from(width) << 16);
            put32(out, u32::from(height) << 16);
        });
        boxed(out, b"edts", |out| {
            full(out, b"elst", 1, 0, |out| {
                put32(out, track.edits.len() as u32);
                for (length, start) in &track.edits {
                    put64(out, *length);
                    put64(out, *start as u64);
                    put32(out, 0x0001_0000);
                }
            });
        });
        boxed(out, b"mdia", |out| {
            full(out, b"mdhd", 1, 0, |out| {
                put64(out, 0);
                put64(out, 0);
                put32(out, track.timescale);
                put64(out, track.media_length());
                put16(out, 0x55c4);
                put16(out, 0);
            });
            full(out, b"hdlr", 0, 0, |out| {
                put32(out, 0);
                out.extend_from_slice(if track.sound { b"soun" } else { b"vide" });
                out.extend_from_slice(&[0; 12]);
                out.extend_from_slice(if track.sound { b"SoundHandler\0" } else { b"VideoHandler\0" });
            });
            boxed(out, b"minf", |out| {
                if track.sound {
                    full(out, b"smhd", 0, 0, |out| put32(out, 0));
                } else {
                    full(out, b"vmhd", 0, 1, |out| out.extend_from_slice(&[0; 8]));
                }
                boxed(out, b"dinf", |out| {
                    full(out, b"dref", 0, 0, |out| {
                        put32(out, 1);
                        full(out, b"url ", 0, 1, |_| {});
                    });
                });
                write_tables(out, track);
            });
        });
    });
}

fn write_tables(out: &mut Vec<u8>, track: &Track) {
    boxed(out, b"stbl", |out| {
        full(out, b"stsd", 0, 0, |out| {
            put32(out, 1);
            out.extend_from_slice(&track.entry);
        });
        let table = |out: &mut Vec<u8>, name: &[u8; 4], values: &[u32]| {
            full(out, name, 0, 0, |out| {
                let runs = runs(values);
                put32(out, runs.len() as u32);
                for (count, value) in runs {
                    put32(out, count);
                    put32(out, value);
                }
            });
        };
        table(out, b"stts", &track.durations);
        if let Some(offsets) = &track.offsets {
            table(out, b"ctts", offsets);
        }
        if let Some(syncs) = &track.syncs {
            full(out, b"stss", 0, 0, |out| {
                put32(out, syncs.len() as u32);
                syncs.iter().for_each(|number| put32(out, *number));
            });
        }
        full(out, b"stsc", 0, 0, |out| {
            put32(out, 1);
            put32(out, 1);
            put32(out, 1);
            put32(out, 1);
        });
        full(out, b"stsz", 0, 0, |out| {
            put32(out, 0);
            put32(out, track.sizes.len() as u32);
            track.sizes.iter().for_each(|size| put32(out, *size));
        });
        full(out, b"co64", 0, 0, |out| {
            put32(out, track.chunks.len() as u32);
            track.chunks.iter().for_each(|at| put64(out, *at));
        });
    });
}
