//! Audio as the speech models hear it: mono samples at one rate, where
//! speech starts in them, and a plain WAV file of them.

/// Changes the rate of mono audio as it arrives: a windowed-sinc low-pass
/// filter, so what the new rate cannot carry is removed instead of folded
/// back into speech.
pub struct Resampler {
    /// Input samples per output sample.
    step: f64,
    /// How far the filter reaches to each side, in input samples.
    reach: usize,
    /// The filter at `PHASES` positions between two input samples.
    table: Vec<f32>,
    /// Input not yet done with; `buffer[0]` is input sample `base`.
    buffer: Vec<f32>,
    base: usize,
    /// How many output samples were written.
    written: usize,
    same: bool,
}

const PHASES: usize = 256;
/// Zero crossings of the filter to each side, at the cutoff's scale.
const LOBES: f64 = 8.0;

impl Resampler {
    pub fn new(from: u32, to: u32) -> Self {
        let step = f64::from(from.max(1)) / f64::from(to.max(1));
        // Pass what both rates carry.
        let cutoff = (1.0 / step).min(1.0);
        let reach = (LOBES / cutoff).ceil() as usize;
        let mut table = Vec::with_capacity((PHASES + 1) * 2 * reach);
        for phase in 0..=PHASES {
            let fraction = phase as f64 / PHASES as f64;
            // Tap `t` weighs the input sample `t - reach + 1` after the
            // position's whole part.
            for tap in 0..2 * reach {
                let distance = fraction - (tap as f64 - reach as f64 + 1.0);
                let x = std::f64::consts::PI * cutoff * distance;
                let sinc = if x.abs() < 1e-9 { 1.0 } else { x.sin() / x };
                let window = 0.5 + 0.5 * (std::f64::consts::PI * distance / reach as f64).cos();
                table.push((cutoff * sinc * window) as f32);
            }
        }
        // The audio starts in silence: the filter may look before it.
        Self { step, reach, table, buffer: vec![0.0; reach], base: 0, written: 0, same: from == to }
    }

    fn drain(&mut self, out: &mut Vec<i16>) {
        let taps = 2 * self.reach;
        loop {
            let position = self.written as f64 * self.step;
            let whole = position as usize;
            // `buffer` begins `reach` samples of silence before the input.
            let first = whole + 1 - self.base;
            if first + taps > self.buffer.len() {
                break;
            }
            let phase = ((position - whole as f64) * PHASES as f64).round() as usize;
            let weights = &self.table[phase * taps..(phase + 1) * taps];
            let sum: f32 = self.buffer[first..first + taps].iter().zip(weights).map(|(x, w)| x * w).sum();
            out.push((sum * 32768.0).clamp(-32768.0, 32767.0) as i16);
            self.written += 1;
        }
        // Forget input no later output reaches back to.
        let keep_from = ((self.written as f64 * self.step) as usize + 1).saturating_sub(self.base);
        if keep_from > 4096 {
            self.buffer.drain(..keep_from);
            self.base += keep_from;
        }
    }

    /// Takes more input, in −1…1, and writes what output it completes.
    pub fn push(&mut self, input: &[f32], out: &mut Vec<i16>) {
        if self.same {
            out.extend(input.iter().map(|x| (x * 32768.0).clamp(-32768.0, 32767.0) as i16));
            return;
        }
        self.buffer.extend_from_slice(input);
        self.drain(out);
    }

    /// Writes the output the last input still owes.
    pub fn finish(&mut self, out: &mut Vec<i16>) {
        if !self.same {
            self.buffer.extend(std::iter::repeat_n(0.0, self.reach));
            self.drain(out);
        }
    }
}

/// Where the speech a word belongs to starts: the aligner often marks a
/// word late, at the end of its first sound. Walks back from `at` over
/// audio louder than the recording's quiet parts, across dips shorter than
/// `bridge` samples, no further than `floor`. All are sample positions.
pub fn speech_onset(samples: &[i16], rate: usize, floor: usize, at: usize, bridge: usize) -> usize {
    let frame = (rate / 50).max(1);
    let at = at.min(samples.len());
    if at <= floor || samples.is_empty() {
        return at;
    }
    let loudness = |start: usize| -> f64 {
        let frame = &samples[start..(start + frame).min(samples.len())];
        (frame.iter().map(|s| f64::from(*s) * f64::from(*s)).sum::<f64>() / frame.len().max(1) as f64).sqrt()
    };
    let mut all: Vec<f64> = (0..samples.len()).step_by(frame).map(loudness).collect();
    all.sort_by(f64::total_cmp);
    // Speech is well above a tenth of the loud frames' level.
    let threshold = (all[all.len() * 9 / 10] * 0.1).max(1.0);
    let (mut start, mut cursor, mut quiet) = (at, at, 0);
    while cursor >= floor + frame && quiet <= bridge {
        cursor -= frame;
        if loudness(cursor) > threshold {
            (start, quiet) = (cursor, 0);
        } else {
            quiet += frame;
        }
    }
    start
}

/// Mono 16-bit samples as a WAV file.
pub fn wav(samples: &[i16], rate: u32) -> Vec<u8> {
    let data = samples.len() as u32 * 2;
    let mut out = Vec::with_capacity(44 + data as usize);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16_u32.to_le_bytes());
    out.extend_from_slice(&1_u16.to_le_bytes());
    out.extend_from_slice(&1_u16.to_le_bytes());
    out.extend_from_slice(&rate.to_le_bytes());
    out.extend_from_slice(&(rate * 2).to_le_bytes());
    out.extend_from_slice(&2_u16.to_le_bytes());
    out.extend_from_slice(&16_u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data.to_le_bytes());
    out.extend(samples.iter().flat_map(|sample| sample.to_le_bytes()));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(rate: u32, hertz: f64, seconds: f64) -> Vec<f32> {
        (0..(f64::from(rate) * seconds) as usize)
            .map(|n| (0.5 * (2.0 * std::f64::consts::PI * hertz * n as f64 / f64::from(rate)).sin()) as f32)
            .collect()
    }

    fn resampled(input: &[f32], from: u32, to: u32) -> Vec<i16> {
        let (mut resampler, mut out) = (Resampler::new(from, to), Vec::new());
        // In uneven pieces, as a decoder hands them over.
        for piece in input.chunks(1000) {
            resampler.push(piece, &mut out);
        }
        resampler.finish(&mut out);
        out
    }

    fn level(samples: &[i16]) -> f64 {
        let middle = &samples[samples.len() / 4..samples.len() * 3 / 4];
        (middle.iter().map(|s| f64::from(*s).powi(2)).sum::<f64>() / middle.len() as f64).sqrt() / 32768.0
    }

    #[test]
    fn resampling_keeps_speech_and_length() {
        let out = resampled(&tone(48_000, 1000.0, 1.0), 48_000, 16_000);
        assert!((out.len() as i64 - 16_000).abs() <= 2, "{} samples", out.len());
        // A sine of amplitude 0.5 has an RMS of 0.354.
        assert!((level(&out) - 0.354).abs() < 0.01, "level {}", level(&out));
        let out = resampled(&tone(44_100, 440.0, 0.5), 44_100, 16_000);
        assert!((out.len() as i64 - 8000).abs() <= 2);
        assert!((level(&out) - 0.354).abs() < 0.01);
    }

    #[test]
    fn resampling_removes_what_the_new_rate_cannot_carry() {
        // 12 kHz cannot be in 16 kHz audio; unfiltered it would return as 4 kHz.
        let out = resampled(&tone(48_000, 12_000.0, 1.0), 48_000, 16_000);
        assert!(level(&out) < 0.005, "level {}", level(&out));
    }

    #[test]
    fn the_same_rate_is_passed_through() {
        assert_eq!(resampled(&[0.5, -0.5, 0.0], 16_000, 16_000), [16384, -16384, 0]);
    }

    #[test]
    fn onset_walks_back_to_where_speech_begins() {
        let mut samples = vec![0_i16; 16_000];
        for (index, sample) in samples.iter_mut().enumerate().skip(1600) {
            *sample = if index % 2 == 0 { 8000 } else { -8000 };
        }
        // Marked at 0.6 s; the sound began at 0.1 s.
        assert_eq!(speech_onset(&samples, 16_000, 0, 9600, 0), 1600);
        assert_eq!(speech_onset(&samples, 16_000, 4800, 9600, 0), 4800, "not past the floor");
        assert_eq!(speech_onset(&samples, 16_000, 0, 800, 0), 800, "silence is left alone");
        // A dip of 60 ms inside the word is crossed when dips that short are allowed.
        samples[4800..5760].fill(0);
        assert_eq!(speech_onset(&samples, 16_000, 0, 9600, 0), 5760);
        assert_eq!(speech_onset(&samples, 16_000, 0, 9600, 1600), 1600);
    }

    #[test]
    fn wav_files_have_a_plain_header() {
        let bytes = wav(&[1, -1], 16_000);
        assert_eq!(bytes.len(), 48);
        assert_eq!(&bytes[..4], b"RIFF");
        assert_eq!(u16::from_le_bytes([bytes[20], bytes[21]]), 1, "PCM");
        assert_eq!(&bytes[44..], [1, 0, 255, 255]);
    }
}
