use std::path::Path;

use listenook_core::{
    audio::Resampler,
    playback::{Loudness, LoudnessMeter},
};
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
    let mut out = Vec::new();
    each_with_symphonia(path, rate, &mut |samples| out.extend_from_slice(samples))?;
    (!out.is_empty()).then_some(out)
}

fn edit_list_skip(path: &Path) -> Option<f64> {
    let extension = path.extension()?.to_str()?.to_ascii_lowercase();
    if !matches!(extension.as_str(), "mp4" | "m4a" | "m4v" | "m4b" | "mov") {
        return None;
    }
    let file = std::fs::File::open(path).ok()?;
    let size = file.metadata().ok()?.len();
    listenook_core::container::mp4_audio_skip(std::io::BufReader::new(file), size)
}

/// Decodes `path` to mono at `rate`, handing the samples to `each` as they
/// come rather than holding them all.
fn each_with_symphonia(path: &Path, rate: u32, each: &mut dyn FnMut(&[i16])) -> Option<()> {
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
    // Leave out the encoder's priming as players do: what an MP4's edit list
    // says, else the usual 2112 samples of AAC, unless symphonia knows it.
    let mut priming = match track.codec_params.delay {
        Some(_) => 0,
        None => match (edit_list_skip(path), track.codec_params.sample_rate) {
            (Some(seconds), Some(native)) => (seconds * f64::from(native)).round() as usize,
            _ if track.codec_params.codec == CODEC_TYPE_AAC => 2112,
            _ => 0,
        },
    };
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
            each(&out);
            out.clear();
        }
    }
    if let Some((_, mut resampler)) = resampler {
        resampler.finish(&mut out);
        each(&out);
    }
    Some(())
}

#[cfg(target_os = "macos")]
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

/// How loud the recording at `source` is, measured once and kept in
/// `temporary` beside the player's files; measured again when the recording
/// changed.
pub(crate) fn loudness(job_id: &str, source: &str) -> Option<Loudness> {
    const RATE: u32 = 16_000;
    let cache = loudness_cache(job_id)?;
    let metadata = std::fs::metadata(source).ok()?;
    let modified = metadata.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?.as_millis();
    let stamp = format!("loudness 1\t{source}\t{}\t{modified}\n", metadata.len());
    if let Ok(bytes) = std::fs::read(&cache)
        && let Some(frames) = bytes.strip_prefix(stamp.as_bytes())
    {
        return Some(Loudness::from_frames(frames.to_vec()));
    }
    let path = Path::new(source);
    let mut meter = LoudnessMeter::new(RATE);
    let streamed = each_with_symphonia(path, RATE, &mut |samples| meter.push(samples));
    let streamed = streamed.map(|()| meter.finish()).filter(|loudness| !loudness.frames().is_empty());
    // What symphonia cannot read whole (an AVI's sound, formats only the
    // system decodes) is decoded the slower way.
    let loudness = match streamed {
        Some(loudness) => loudness,
        None => Loudness::measure(&decode(path, RATE)?, RATE),
    };
    if loudness.frames().is_empty() {
        return None;
    }
    let mut bytes = stamp.into_bytes();
    bytes.extend_from_slice(loudness.frames());
    if std::fs::create_dir_all(cache.parent()?).is_ok() {
        let part = cache.with_extension("part");
        if std::fs::write(&part, bytes).is_ok() {
            let _ = std::fs::rename(&part, &cache);
        }
    }
    Some(loudness)
}

pub(crate) fn forget_loudness(job_id: &str) {
    if let Some(cache) = loudness_cache(job_id) {
        let _ = std::fs::remove_file(cache);
    }
}

fn loudness_cache(job_id: &str) -> Option<std::path::PathBuf> {
    Some(crate::state::persist::data_root()?.join("temporary").join(format!("{job_id}-loudness.bin")))
}

pub(crate) fn decode(path: &Path, rate: u32) -> Option<Vec<i16>> {
    decode_with_symphonia(path, rate).or_else(|| decode_avi(path, rate)).or_else(|| decode_with_system(path, rate))
}

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
