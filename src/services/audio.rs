//! A recording's audio as mono samples, decoded in the app (the Symphonia
//! crate) so it works the same on every platform. What Symphonia cannot
//! read, macOS's converter is asked for.

use std::path::Path;

use listenook_core::audio::Resampler;
use symphonia::core::{
    audio::SampleBuffer,
    codecs::{CODEC_TYPE_AAC, CODEC_TYPE_NULL, DecoderOptions},
    errors::Error,
    formats::FormatOptions,
    io::MediaSourceStream,
    meta::MetadataOptions,
    probe::Hint,
};

fn decode_with_symphonia(path: &Path, rate: u32) -> Option<Vec<i16>> {
    let stream = MediaSourceStream::new(Box::new(std::fs::File::open(path).ok()?), Default::default());
    let mut hint = Hint::new();
    if let Some(extension) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(extension);
    }
    let probed = symphonia::default::get_probe()
        .format(
            &hint,
            stream,
            &FormatOptions { enable_gapless: true, ..Default::default() },
            &MetadataOptions::default(),
        )
        .ok()?;
    let mut format = probed.format;
    let track = format.tracks().iter().find(|track| track.codec_params.codec != CODEC_TYPE_NULL)?;
    let track_id = track.id;
    // An AAC stream begins with the encoder's priming samples. Where the
    // file does not say how many, it is the 2112 every common encoder
    // writes; left in, every word would be timed a tenth of a second late.
    let mut priming =
        if track.codec_params.codec == CODEC_TYPE_AAC && track.codec_params.delay.is_none() { 2112_usize } else { 0 };
    let mut decoder = symphonia::default::get_codecs().make(&track.codec_params, &DecoderOptions::default()).ok()?;
    let mut out = Vec::new();
    let mut resampler: Option<(u32, Resampler)> = None;
    let mut mono = Vec::new();
    while let Ok(packet) = format.next_packet() {
        if packet.track_id() != track_id {
            continue;
        }
        let decoded = match decoder.decode(&packet) {
            Ok(decoded) => decoded,
            // A damaged packet: the rest may still play.
            Err(Error::DecodeError(_)) => continue,
            Err(_) => break,
        };
        let spec = *decoded.spec();
        let channels = spec.channels.count().max(1);
        let mut buffer = SampleBuffer::<f32>::new(decoded.capacity() as u64, spec);
        buffer.copy_interleaved_ref(decoded);
        mono.clear();
        mono.extend(buffer.samples().chunks(channels).map(|frame| frame.iter().sum::<f32>() / channels as f32));
        let skipped = priming.min(mono.len());
        priming -= skipped;
        let mono = &mono[skipped..];
        if resampler.as_ref().is_none_or(|(from, _)| *from != spec.rate) {
            resampler = Some((spec.rate, Resampler::new(spec.rate, rate)));
        }
        if let Some((_, resampler)) = &mut resampler {
            resampler.push(mono, &mut out);
        }
    }
    if let Some((_, mut resampler)) = resampler {
        resampler.finish(&mut out);
    }
    (!out.is_empty()).then_some(out)
}

#[cfg(target_os = "macos")]
/// The samples of a 16-bit PCM WAV file's `data` chunk.
fn wav_samples(bytes: &[u8]) -> Vec<i16> {
    let mut at = 12;
    while at + 8 <= bytes.len() {
        let size = u32::from_le_bytes([bytes[at + 4], bytes[at + 5], bytes[at + 6], bytes[at + 7]]) as usize;
        let (start, end) = (at + 8, (at + 8 + size).min(bytes.len()));
        if &bytes[at..at + 4] == b"data" {
            return bytes[start..end].as_chunks::<2>().0.iter().map(|pair| i16::from_le_bytes(*pair)).collect();
        }
        at = end + (size & 1);
    }
    Vec::new()
}

#[cfg(target_os = "macos")]
fn decode_with_system(path: &Path, rate: u32) -> Option<Vec<i16>> {
    let wav = std::env::temp_dir().join(format!("listenook-{}.wav", uuid::Uuid::new_v4().simple()));
    let converted = std::process::Command::new("/usr/bin/afconvert")
        .args(["-f", "WAVE", "-d", &format!("LEI16@{rate}"), "-c", "1"])
        .arg(path)
        .arg(&wav)
        .output()
        .is_ok_and(|out| out.status.success());
    let bytes = std::fs::read(&wav).ok();
    let _ = std::fs::remove_file(&wav);
    let samples = wav_samples(&bytes.filter(|_| converted)?);
    (!samples.is_empty()).then_some(samples)
}

#[cfg(not(target_os = "macos"))]
fn decode_with_system(_: &Path, _: u32) -> Option<Vec<i16>> {
    None
}

/// The audio of a media file as mono 16-bit samples at `rate`, or none
/// when nothing here can read it. Blocks: call it off the engine thread.
pub(crate) fn decode(path: &Path, rate: u32) -> Option<Vec<i16>> {
    decode_with_symphonia(path, rate).or_else(|| decode_avi(path, rate)).or_else(|| decode_with_system(path, rate))
}

/// An AVI file's sound: its track is taken out, then decoded.
fn decode_avi(path: &Path, rate: u32) -> Option<Vec<i16>> {
    if !path.extension().is_some_and(|extension| extension.eq_ignore_ascii_case("avi")) {
        return None;
    }
    let stem = std::env::temp_dir().join(format!("listenook-{}", uuid::Uuid::new_v4().simple()));
    let sound = super::playable::avi_sound_file(path, &stem)?;
    let samples = decode_with_symphonia(&sound, rate);
    let _ = std::fs::remove_file(&sound);
    samples
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    #[test]
    fn wav_data_is_found_after_other_chunks() {
        let mut wav = b"RIFF\0\0\0\0WAVEfmt \x02\0\0\0\x01\0data\x04\0\0\0".to_vec();
        wav.extend([1, 0, 0xff, 0x7f]);
        assert_eq!(wav_samples(&wav), [1, i16::MAX]);
    }
}
