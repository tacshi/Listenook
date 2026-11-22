//! Recording what the computer plays: its loudness as it comes in, the silent
//! stretches worth cutting out, the parts kept once it is trimmed, and the WAV
//! files it is written to and spliced from.

use std::{
    fs::File,
    io::{self, BufReader, BufWriter, Read, Seek, SeekFrom, Write},
    path::Path,
};

/// Loudness is kept per 10 ms: 100 values a second.
pub const LEVELS_PER_SECOND: u32 = 100;
const LEVEL_MS: u64 = 1000 / LEVELS_PER_SECOND as u64;

/// A peak under −50 dBFS is silence: a paused video, the gap between two, a
/// page still loading.
pub const SILENT: f32 = 0.003_162;

/// A stretch this long without sound, inside a recording, is a gap to cut.
pub const GAP_MS: u64 = 2_000;
/// What is left of a gap on each side of the cut: a pause, not a jump.
pub const GAP_KEEP_MS: u64 = 300;
/// What is left of the silence before the first sound and after the last.
pub const EDGE_KEEP_MS: u64 = 150;

/// How long each join fades out and in, so a cut never clicks.
const FADE_MS: u64 = 8;

/// A stretch of a recording, in milliseconds from its start.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Span {
    pub start_ms: u64,
    pub end_ms: u64,
}

impl Span {
    pub fn new(start_ms: u64, end_ms: u64) -> Self {
        Self { start_ms, end_ms: end_ms.max(start_ms) }
    }

    pub fn len_ms(&self) -> u64 {
        self.end_ms - self.start_ms
    }

    pub fn contains(&self, ms: u64) -> bool {
        (self.start_ms..self.end_ms).contains(&ms)
    }
}

/// The peak of interleaved frames per 10 ms, as they come in.
#[derive(Debug, Clone)]
pub struct Meter {
    channels: usize,
    window: usize,
    filled: usize,
    peak: f32,
}

impl Meter {
    pub fn new(rate: u32, channels: u16) -> Self {
        Self {
            channels: usize::from(channels.max(1)),
            window: (rate / LEVELS_PER_SECOND).max(1) as usize,
            filled: 0,
            peak: 0.0,
        }
    }

    /// Adds `samples` (interleaved frames), appending a level to `levels`
    /// for each 10 ms they complete.
    pub fn push(&mut self, samples: &[f32], levels: &mut Vec<f32>) {
        for frame in samples.chunks_exact(self.channels) {
            let loudest = frame.iter().fold(0.0_f32, |peak, sample| peak.max(sample.abs()));
            self.peak = self.peak.max(loudest);
            self.filled += 1;
            if self.filled == self.window {
                levels.push(self.peak.min(1.0));
                self.filled = 0;
                self.peak = 0.0;
            }
        }
    }
}

/// The local date and time a recording is named after: `2026-11-22 14:03`.
pub fn stamp() -> String {
    stamp_at(std::time::SystemTime::now())
}

/// [`stamp`] of `time`.
pub fn stamp_at(time: std::time::SystemTime) -> String {
    chrono::DateTime::<chrono::Local>::from(time).format("%Y-%m-%d %H:%M").to_string()
}

/// Converts float samples to 16-bit ones, appending them to `out`.
pub fn pcm16(samples: &[f32], out: &mut Vec<i16>) {
    out.extend(samples.iter().map(|sample| (sample * 32768.0).clamp(-32768.0, 32767.0) as i16));
}

/// How long `levels` last.
pub fn levels_ms(levels: &[f32]) -> u64 {
    levels.len() as u64 * LEVEL_MS
}

/// Whether anything louder than silence was heard.
pub fn heard(levels: &[f32]) -> bool {
    levels.iter().any(|level| *level >= SILENT)
}

/// The silent stretches of a recording worth cutting out, in order: the
/// silence before its first sound and after its last (but a moment beside
/// the sound), and gaps of [`GAP_MS`] or more between sounds (but
/// [`GAP_KEEP_MS`] at each side, a natural pause). A recording that is all
/// silence is one gap.
pub fn gaps(levels: &[f32]) -> Vec<Span> {
    let count = levels.len();
    let mut found = Vec::new();
    let mut at = 0;
    while at < count {
        if levels[at] >= SILENT {
            at += 1;
            continue;
        }
        let first = at;
        while at < count && levels[at] < SILENT {
            at += 1;
        }
        let (start, end) = (first as u64 * LEVEL_MS, at as u64 * LEVEL_MS);
        let length = end - start;
        let span = match (first == 0, at == count) {
            (true, true) => Some(Span::new(start, end)),
            (true, false) => (length > EDGE_KEEP_MS * 2).then(|| Span::new(start, end - EDGE_KEEP_MS)),
            (false, true) => (length > EDGE_KEEP_MS * 2).then(|| Span::new(start + EDGE_KEEP_MS, end)),
            (false, false) => (length >= GAP_MS).then(|| Span::new(start + GAP_KEEP_MS, end - GAP_KEEP_MS)),
        };
        found.extend(span);
    }
    found
}

/// How a recording is trimmed: where it starts and ends, and whether its
/// silent gaps are cut out.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Trim {
    pub start_ms: u64,
    pub end_ms: u64,
    pub cut_gaps: bool,
}

/// The parts of a recording that `trim` keeps, in order.
pub fn kept(trim: &Trim, gaps: &[Span]) -> Vec<Span> {
    let mut spans = Vec::new();
    let mut at = trim.start_ms;
    if trim.cut_gaps {
        for gap in gaps {
            if gap.end_ms <= at {
                continue;
            }
            if gap.start_ms >= trim.end_ms {
                break;
            }
            if gap.start_ms > at {
                spans.push(Span::new(at, gap.start_ms));
            }
            at = gap.end_ms;
        }
    }
    if at < trim.end_ms {
        spans.push(Span::new(at, trim.end_ms));
    }
    spans
}

/// How long `spans` last together.
pub fn total_ms(spans: &[Span]) -> u64 {
    spans.iter().map(Span::len_ms).sum()
}

/// Where playback at `position_ms` goes on so it plays only what is kept:
/// there when it is kept, else at the start of the next kept part; `None`
/// past the last one.
pub fn next_kept(kept: &[Span], position_ms: u64) -> Option<u64> {
    kept.iter().find(|span| span.end_ms > position_ms).map(|span| span.start_ms.max(position_ms))
}

/// The loudness of `levels` from `start_ms` to `end_ms` as `count` bars,
/// each the peak of its stretch on a decibel scale: 0 for silence, 1 for
/// full scale.
pub fn bars(levels: &[f32], start_ms: u64, end_ms: u64, count: usize) -> Vec<f32> {
    if count == 0 || end_ms <= start_ms || levels.is_empty() {
        return vec![0.0; count];
    }
    let (first, last) = (start_ms / LEVEL_MS, end_ms.div_ceil(LEVEL_MS));
    let span = (last - first) as f64;
    (0..count)
        .map(|bar| {
            let from = first + (span * bar as f64 / count as f64) as u64;
            let to = (first + (span * (bar + 1) as f64 / count as f64) as u64).max(from + 1);
            let peak =
                (from..to).filter_map(|index| levels.get(index as usize)).fold(0.0_f32, |peak, level| peak.max(*level));
            loudness(peak)
        })
        .collect()
}

/// A peak on the scale [`bars`] draws: 0 at [`SILENT`], 1 at full scale.
pub fn loudness(peak: f32) -> f32 {
    if peak < SILENT {
        return 0.0;
    }
    let floor = 20.0 * SILENT.log10();
    ((20.0 * peak.log10() - floor) / -floor).clamp(0.0, 1.0)
}

/// A 16-bit PCM WAV file written as it is recorded.
pub struct WavWriter {
    file: BufWriter<File>,
    channels: u16,
    rate: u32,
    frames: u64,
}

impl WavWriter {
    pub fn create(path: &Path, rate: u32, channels: u16) -> io::Result<Self> {
        let mut writer = Self { file: BufWriter::new(File::create(path)?), channels: channels.max(1), rate, frames: 0 };
        writer.header()?;
        Ok(writer)
    }

    fn header(&mut self) -> io::Result<()> {
        let block = u32::from(self.channels) * 2;
        let data = u32::try_from(self.frames * u64::from(block)).unwrap_or(u32::MAX - 36);
        let file = &mut self.file;
        file.write_all(b"RIFF")?;
        file.write_all(&(36 + data).to_le_bytes())?;
        file.write_all(b"WAVEfmt ")?;
        file.write_all(&16_u32.to_le_bytes())?;
        file.write_all(&1_u16.to_le_bytes())?;
        file.write_all(&self.channels.to_le_bytes())?;
        file.write_all(&self.rate.to_le_bytes())?;
        file.write_all(&(self.rate * block).to_le_bytes())?;
        file.write_all(&(block as u16).to_le_bytes())?;
        file.write_all(&16_u16.to_le_bytes())?;
        file.write_all(b"data")?;
        file.write_all(&data.to_le_bytes())
    }

    /// Appends interleaved samples (whole frames).
    pub fn write(&mut self, samples: &[i16]) -> io::Result<()> {
        let mut bytes = Vec::with_capacity(samples.len() * 2);
        for sample in samples {
            bytes.extend_from_slice(&sample.to_le_bytes());
        }
        self.file.write_all(&bytes)?;
        self.frames += (samples.len() / usize::from(self.channels)) as u64;
        Ok(())
    }

    pub fn frames(&self) -> u64 {
        self.frames
    }

    /// Writes what is buffered and the sizes into the header, so the file
    /// plays as far as it goes should the app stop before [`Self::finish`].
    pub fn sync(&mut self) -> io::Result<()> {
        self.file.seek(SeekFrom::Start(0))?;
        self.header()?;
        self.file.seek(SeekFrom::End(0))?;
        self.file.flush()
    }

    /// Ends the file; how many frames it holds.
    pub fn finish(mut self) -> io::Result<u64> {
        self.sync()?;
        self.file.get_ref().sync_all()?;
        Ok(self.frames)
    }
}

/// What a WAV file holds and where.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WavInfo {
    pub rate: u32,
    pub channels: u16,
    pub bits: u16,
    pub data_at: u64,
    /// Its sound's bytes, whole frames: what the file holds when the header
    /// says less (a file not finished) or more (one cut short).
    pub data_len: u64,
}

impl WavInfo {
    pub fn frames(&self) -> u64 {
        self.data_len / u64::from(self.block())
    }

    pub fn duration_ms(&self) -> u64 {
        self.frames() * 1000 / u64::from(self.rate.max(1))
    }

    fn block(&self) -> u32 {
        u32::from(self.channels.max(1)) * u32::from(self.bits / 8).max(1)
    }
}

/// Reads a WAV file's header.
pub fn wav_info(reader: &mut (impl Read + Seek)) -> io::Result<WavInfo> {
    let invalid = |what: &str| io::Error::new(io::ErrorKind::InvalidData, what.to_owned());
    let size = reader.seek(SeekFrom::End(0))?;
    reader.seek(SeekFrom::Start(0))?;
    let mut riff = [0; 12];
    reader.read_exact(&mut riff)?;
    if &riff[0..4] != b"RIFF" || &riff[8..12] != b"WAVE" {
        return Err(invalid("not a WAV file"));
    }
    let mut format = None;
    let mut at = 12;
    while at + 8 <= size {
        let mut chunk = [0; 8];
        reader.seek(SeekFrom::Start(at))?;
        reader.read_exact(&mut chunk)?;
        let length = u64::from(u32::from_le_bytes([chunk[4], chunk[5], chunk[6], chunk[7]]));
        match &chunk[0..4] {
            b"fmt " => {
                let mut fmt = [0; 16];
                reader.read_exact(&mut fmt)?;
                let channels = u16::from_le_bytes([fmt[2], fmt[3]]);
                let rate = u32::from_le_bytes([fmt[4], fmt[5], fmt[6], fmt[7]]);
                let bits = u16::from_le_bytes([fmt[14], fmt[15]]);
                format = Some((rate, channels, bits));
            }
            b"data" => {
                let (rate, channels, bits) = format.ok_or_else(|| invalid("no format before the sound"))?;
                let mut info = WavInfo { rate, channels, bits, data_at: at + 8, data_len: 0 };
                let held = size - info.data_at;
                let length = if length == 0 || length > held { held } else { length };
                info.data_len = length - length % u64::from(info.block());
                return Ok(info);
            }
            _ => {}
        }
        at += 8 + length + (length & 1);
    }
    Err(invalid("no sound in the WAV file"))
}

/// The levels of the 16-bit WAV at `path` (a recording left by a run that
/// ended before it was saved), and what it holds.
pub fn levels_of(path: &Path) -> io::Result<(Vec<f32>, WavInfo)> {
    let mut reader = BufReader::new(File::open(path)?);
    let info = wav_info(&mut reader)?;
    if info.bits != 16 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "not 16-bit"));
    }
    reader.seek(SeekFrom::Start(info.data_at))?;
    let mut meter = Meter::new(info.rate, info.channels);
    let mut levels = Vec::new();
    let mut left = info.data_len;
    let mut bytes = vec![0; 1 << 16];
    let mut samples = Vec::with_capacity(bytes.len() / 2);
    while left > 0 {
        let take = left.min(bytes.len() as u64) as usize;
        reader.read_exact(&mut bytes[..take])?;
        samples.clear();
        samples
            .extend(bytes[..take].as_chunks::<2>().0.iter().map(|pair| f32::from(i16::from_le_bytes(*pair)) / 32768.0));
        meter.push(&samples, &mut levels);
        left -= take as u64;
    }
    Ok((levels, info))
}

/// Copies the `spans` of the 16-bit WAV at `from` into a new one at `to`,
/// one after another, each fading in and out over a few milliseconds so the
/// joins do not click. How many frames it wrote.
pub fn splice(from: &Path, spans: &[Span], to: &Path) -> io::Result<u64> {
    let mut reader = BufReader::new(File::open(from)?);
    let info = wav_info(&mut reader)?;
    if info.bits != 16 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "not 16-bit"));
    }
    let channels = usize::from(info.channels.max(1));
    let block = channels as u64 * 2;
    let frame_of = |ms: u64| (ms * u64::from(info.rate) / 1000).min(info.frames());
    let fade = (FADE_MS * u64::from(info.rate) / 1000).max(1);
    let mut writer = WavWriter::create(to, info.rate, info.channels)?;
    let mut bytes = vec![0; 4096 * block as usize];
    let mut samples = Vec::with_capacity(4096 * channels);
    for span in spans {
        let (first, last) = (frame_of(span.start_ms), frame_of(span.end_ms));
        if last <= first {
            continue;
        }
        let length = last - first;
        reader.seek(SeekFrom::Start(info.data_at + first * block))?;
        let mut done = 0;
        while done < length {
            let take = (length - done).min(4096);
            let read = &mut bytes[..(take * block) as usize];
            reader.read_exact(read)?;
            samples.clear();
            for (index, frame) in read.chunks_exact(block as usize).enumerate() {
                let at = done + index as u64;
                let edge = at.min(length - 1 - at);
                let gain = if edge < fade { edge as f32 / fade as f32 } else { 1.0 };
                samples.extend(
                    frame.as_chunks::<2>().0.iter().map(|pair| (f32::from(i16::from_le_bytes(*pair)) * gain) as i16),
                );
            }
            writer.write(&samples)?;
            done += take;
        }
    }
    writer.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn levels(parts: &[(f32, u64)]) -> Vec<f32> {
        parts.iter().flat_map(|(level, ms)| std::iter::repeat_n(*level, (*ms / LEVEL_MS) as usize)).collect()
    }

    #[test]
    fn the_meter_keeps_the_peak_of_each_ten_milliseconds() {
        let mut meter = Meter::new(48_000, 2);
        let mut kept = Vec::new();
        let mut frames = vec![0.1_f32; 480 * 2];
        frames[7] = -0.5;
        meter.push(&frames, &mut kept);
        meter.push(&[0.9; 200], &mut kept);
        assert_eq!(kept, vec![0.5]);
        meter.push(&[0.2; 760], &mut kept);
        assert_eq!(kept, vec![0.5, 0.9]);
    }

    #[test]
    fn silence_at_the_edges_is_cut_but_a_moment_beside_the_sound() {
        let found = gaps(&levels(&[(0.0, 1_000), (0.5, 2_000), (0.0, 3_000)]));
        assert_eq!(found, vec![Span::new(0, 850), Span::new(3_150, 6_000)]);
    }

    #[test]
    fn only_long_gaps_inside_are_cut_and_a_pause_is_left() {
        let found = gaps(&levels(&[(0.5, 1_000), (0.0, 1_500), (0.5, 1_000), (0.0, 4_000), (0.5, 1_000)]));
        assert_eq!(found, vec![Span::new(3_800, 7_200)]);
    }

    #[test]
    fn a_silent_recording_is_one_gap_and_nothing_is_heard() {
        let silent = levels(&[(0.001, 2_000)]);
        assert_eq!(gaps(&silent), vec![Span::new(0, 2_000)]);
        assert!(!heard(&silent));
        assert!(heard(&levels(&[(0.0, 500), (0.01, 10)])));
    }

    #[test]
    fn trimming_keeps_what_lies_between_the_ends_and_outside_the_gaps() {
        let gaps = vec![Span::new(0, 850), Span::new(3_800, 7_200), Span::new(8_150, 10_000)];
        let all = Trim { start_ms: 0, end_ms: 10_000, cut_gaps: true };
        assert_eq!(kept(&all, &gaps), vec![Span::new(850, 3_800), Span::new(7_200, 8_150)]);
        assert_eq!(total_ms(&kept(&all, &gaps)), 3_900);
        let inside = Trim { start_ms: 2_000, end_ms: 7_500, cut_gaps: true };
        assert_eq!(kept(&inside, &gaps), vec![Span::new(2_000, 3_800), Span::new(7_200, 7_500)]);
        let uncut = Trim { start_ms: 2_000, end_ms: 7_500, cut_gaps: false };
        assert_eq!(kept(&uncut, &gaps), vec![Span::new(2_000, 7_500)]);
        let in_a_gap = Trim { start_ms: 4_000, end_ms: 7_000, cut_gaps: true };
        assert!(kept(&in_a_gap, &gaps).is_empty());
    }

    #[test]
    fn preview_skips_to_the_next_kept_part() {
        let kept = vec![Span::new(850, 3_800), Span::new(7_200, 8_150)];
        assert_eq!(next_kept(&kept, 0), Some(850));
        assert_eq!(next_kept(&kept, 1_000), Some(1_000));
        assert_eq!(next_kept(&kept, 3_800), Some(7_200));
        assert_eq!(next_kept(&kept, 8_150), None);
    }

    #[test]
    fn bars_show_each_stretch_s_peak_on_a_decibel_scale() {
        let shown = bars(&levels(&[(0.0, 1_000), (1.0, 1_000), (0.1, 1_000), (0.0, 1_000)]), 0, 4_000, 4);
        assert_eq!(shown[0], 0.0);
        assert_eq!(shown[1], 1.0);
        assert!((shown[2] - 0.6).abs() < 0.01, "{shown:?}");
        assert_eq!(shown[3], 0.0);
        assert_eq!(bars(&[], 0, 1_000, 3), vec![0.0; 3]);
        assert_eq!(bars(&levels(&[(1.0, 100)]), 0, 100, 40).len(), 40);
    }

    #[test]
    fn a_wav_written_in_pieces_reads_back_and_splices_with_fades() {
        let folder = std::env::temp_dir().join(format!("listenook-capture-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        let (whole, cut) = (folder.join("whole.wav"), folder.join("cut.wav"));
        let mut writer = WavWriter::create(&whole, 1_000, 2).unwrap();
        let mut samples = Vec::new();
        for frame in 0..3_000 {
            samples.extend([1_000_i16 + (frame / 1_000) as i16, -1_000]);
        }
        writer.write(&samples[..2_000]).unwrap();
        writer.sync().unwrap();
        let mut reader = File::open(&whole).unwrap();
        assert_eq!(wav_info(&mut reader).unwrap().frames(), 1_000);
        writer.write(&samples[2_000..]).unwrap();
        assert_eq!(writer.finish().unwrap(), 3_000);

        let (levels, info) = levels_of(&whole).unwrap();
        assert_eq!((info.rate, info.channels, info.duration_ms()), (1_000, 2, 3_000));
        assert_eq!(levels.len(), 300);

        let frames = splice(&whole, &[Span::new(0, 500), Span::new(2_000, 2_600)], &cut).unwrap();
        assert_eq!(frames, 1_100);
        let mut reader = File::open(&cut).unwrap();
        let info = wav_info(&mut reader).unwrap();
        assert_eq!(info.frames(), 1_100);
        let mut bytes = Vec::new();
        reader.seek(SeekFrom::Start(info.data_at)).unwrap();
        reader.read_to_end(&mut bytes).unwrap();
        let left: Vec<i16> =
            bytes.as_chunks::<4>().0.iter().map(|frame| i16::from_le_bytes([frame[0], frame[1]])).collect::<Vec<_>>();
        assert_eq!(left[0], 0, "each part fades in");
        assert_eq!(left[250], 1_000);
        assert_eq!(left[600], 1_002, "the second part comes from two seconds in");
        assert_eq!(left[499], 0, "and the first fades out");
        let _ = std::fs::remove_dir_all(folder);
    }
}
