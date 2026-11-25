use std::path::Path;

use listenook_core::{
    audio::Resampler,
    playback::{Loudness, LoudnessMeter},
};
use symphonia::core::{
    audio::SampleBuffer,
    codecs::{CODEC_TYPE_AAC, CODEC_TYPE_NULL, CODEC_TYPE_OPUS, CodecParameters, DecoderOptions},
    errors::Error,
    formats::{FormatOptions, Packet},
    io::MediaSourceStream,
    meta::MetadataOptions,
    probe::Hint,
};
use symphonia_next::{
    codecs::audio::{AudioCodecParameters, AudioDecoder, AudioDecoderOptions, well_known::CODEC_ID_OPUS},
    packet::PacketBuilder,
};

/// What a packet decoded to.
enum Decoded {
    /// Its sound, at this many samples a second.
    Sound(u32),
    /// Nothing: the packet was damaged, and the ones after it may still be read.
    Unreadable,
    /// Nothing more can be read.
    End,
}

/// Decodes a track's packets to mono. Opus, the sound of most videos saved from the web, has
/// no decoder in symphonia: one written for its next version is handed the packets instead,
/// which this version still reads from more files than the next one does.
enum Decoder {
    Symphonia(Box<dyn symphonia::core::codecs::Decoder>),
    Opus(Box<symphonia_opus::OpusDecoder>),
}

impl Decoder {
    fn new(params: &CodecParameters) -> Option<Decoder> {
        if params.codec != CODEC_TYPE_OPUS {
            let decoder = symphonia::default::get_codecs().make(params, &DecoderOptions::default()).ok()?;
            return Some(Decoder::Symphonia(decoder));
        }
        let mut opus = AudioCodecParameters::new();
        opus.for_codec(CODEC_ID_OPUS);
        if let Some(rate) = params.sample_rate {
            opus.with_sample_rate(rate);
        }
        if let Some(header) = &params.extra_data {
            opus.with_extra_data(header.clone());
        }
        let decoder = symphonia_opus::OpusDecoder::try_new(&opus, &AudioDecoderOptions::default()).ok()?;
        Some(Decoder::Opus(Box::new(decoder)))
    }

    /// The samples the encoder put before the sound, when the file doesn't say.
    fn priming(&self) -> usize {
        match self {
            Decoder::Symphonia(_) => 0,
            Decoder::Opus(opus) => {
                let rate = opus.codec_params().sample_rate.unwrap_or(48_000);
                (u64::from(opus.pre_skip()) * u64::from(rate) / 48_000) as usize
            }
        }
    }

    /// Decodes `packet` into `mono`, in place of what it held.
    fn decode(&mut self, packet: &Packet, mono: &mut Vec<f32>) -> Decoded {
        mono.clear();
        match self {
            Decoder::Symphonia(decoder) => {
                let decoded = match decoder.decode(packet) {
                    Ok(decoded) => decoded,
                    Err(Error::DecodeError(_)) => return Decoded::Unreadable,
                    Err(_) => return Decoded::End,
                };
                let spec = *decoded.spec();
                let mut buffer = SampleBuffer::<f32>::new(decoded.capacity() as u64, spec);
                buffer.copy_interleaved_ref(decoded);
                downmix(buffer.samples(), spec.channels.count(), mono);
                Decoded::Sound(spec.rate)
            }
            Decoder::Opus(decoder) => {
                let next = PacketBuilder::new()
                    .track_id(packet.track_id())
                    .pts(Default::default())
                    .dur(Default::default())
                    .data_by_ref(packet.buf())
                    .build_packet_ref();
                let decoded = match decoder.decode_ref(&next) {
                    Ok(decoded) => decoded,
                    Err(symphonia_next::errors::Error::DecodeError(_)) => return Decoded::Unreadable,
                    Err(_) => return Decoded::End,
                };
                let (rate, channels) = (decoded.spec().rate(), decoded.spec().channels().count());
                let mut samples = Vec::new();
                decoded.copy_to_vec_interleaved(&mut samples);
                downmix(&samples, channels, mono);
                // Symphonia's own decoders leave out what the file marks as gap; this one can't
                // know of it.
                let end = mono.len().saturating_sub(packet.trim_end() as usize);
                mono.truncate(end);
                mono.drain(..(packet.trim_start() as usize).min(end));
                Decoded::Sound(rate)
            }
        }
    }
}

fn downmix(interleaved: &[f32], channels: usize, mono: &mut Vec<f32>) {
    let channels = channels.max(1);
    mono.extend(interleaved.chunks(channels).map(|frame| frame.iter().sum::<f32>() / channels as f32));
}

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
    let mut decoder = Decoder::new(&track.codec_params)?;
    let mut priming = match track.codec_params.delay {
        Some(_) => 0,
        None => match (edit_list_skip(path), track.codec_params.sample_rate) {
            (Some(seconds), Some(native)) => (seconds * f64::from(native)).round() as usize,
            _ if track.codec_params.codec == CODEC_TYPE_AAC => 2112,
            _ => decoder.priming(),
        },
    };
    let mut out = Vec::new();
    let mut resampler: Option<(u32, Resampler)> = None;
    let mut mono = Vec::new();
    while let Ok(packet) = format.next_packet() {
        if packet.track_id() != track_id {
            continue;
        }
        let native = match decoder.decode(&packet, &mut mono) {
            Decoded::Sound(native) => native,
            Decoded::Unreadable => continue,
            Decoded::End => break,
        };
        let skipped = priming.min(mono.len());
        priming -= skipped;
        let mono = &mono[skipped..];
        if resampler.as_ref().is_none_or(|(from, _)| *from != native) {
            resampler = Some((native, Resampler::new(native, rate)));
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

#[cfg(test)]
mod opus_tests {
    use super::*;

    #[test]
    fn the_opus_sound_of_a_matroska_video_is_decoded() {
        let path = Path::new(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/data/tone-opus.mkv"));
        let samples = decode_with_symphonia(path, 16_000).expect("Opus is decoded");
        // One second of a 440 Hz tone in 20 ms packets, the encoder's priming left out: the
        // last packet's padding stays, as this file doesn't mark it.
        assert_eq!(samples.len(), (51 * 960 - 312) / 3);
        let loudest = samples.iter().map(|sample| sample.unsigned_abs()).max().unwrap_or(0);
        assert!(loudest > 2_000, "a tone, not silence: {loudest}");
    }
}
