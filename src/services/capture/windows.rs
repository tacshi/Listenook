//! A WASAPI loopback of the default output (everything the speakers play),
//! and Media Foundation's AAC encoder for the file kept.

use std::{
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    thread::JoinHandle,
    time::{Duration, Instant},
};

use listenook_core::capture::wav_info;
use windows::{
    Win32::{
        Media::{
            Audio::{
                AUDCLNT_BUFFERFLAGS_SILENT, AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK,
                IAudioCaptureClient, IAudioClient, IMMDeviceEnumerator, MMDeviceEnumerator, WAVEFORMATEX,
                WAVEFORMATEXTENSIBLE, eConsole, eRender,
            },
            KernelStreaming::WAVE_FORMAT_EXTENSIBLE,
            MediaFoundation::{
                IMFSinkWriter, MF_MT_AUDIO_AVG_BYTES_PER_SECOND, MF_MT_AUDIO_BITS_PER_SAMPLE,
                MF_MT_AUDIO_BLOCK_ALIGNMENT, MF_MT_AUDIO_NUM_CHANNELS, MF_MT_AUDIO_SAMPLES_PER_SECOND,
                MF_MT_MAJOR_TYPE, MF_MT_SUBTYPE, MF_VERSION, MFAudioFormat_AAC, MFAudioFormat_PCM, MFCreateMediaType,
                MFCreateMemoryBuffer, MFCreateSample, MFCreateSinkWriterFromURL, MFMediaType_Audio, MFSTARTUP_FULL,
                MFShutdown, MFStartup,
            },
            Multimedia::{KSDATAFORMAT_SUBTYPE_IEEE_FLOAT, WAVE_FORMAT_IEEE_FLOAT},
        },
        System::Com::{
            CLSCTX_ALL, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize,
        },
    },
    core::HSTRING,
};

use super::{Sink, Stream};

/// What reaches the capture thread from the loopback, and how to read it.
struct Loopback {
    client: IAudioClient,
    capture: IAudioCaptureClient,
    rate: u32,
    channels: usize,
    /// Where the front center is, mixed into both sides; `None` without one.
    center: Option<usize>,
    sample: Sample,
}

#[derive(Clone, Copy)]
enum Sample {
    Float,
    Int16,
    Int32,
}

struct Running {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl Stream for Running {}

impl Drop for Running {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

pub(super) fn open(sink: Sink) -> Result<(u32, Box<dyn Stream>), &'static str> {
    let (ready, opened) = mpsc::channel();
    let stop = Arc::new(AtomicBool::new(false));
    let stopping = stop.clone();
    let thread = std::thread::Builder::new()
        .name("capture-loopback".into())
        .spawn(move || {
            let _ = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
            match unsafe { Loopback::open() } {
                Ok(loopback) => {
                    let _ = ready.send(Some(loopback.rate));
                    if let Err(error) = unsafe { loopback.run(&sink, &stopping) } {
                        log::error!("capture: the loopback stopped: {error}");
                    }
                    let _ = unsafe { loopback.client.Stop() };
                }
                Err(error) => {
                    log::error!("capture: opening the loopback: {error}");
                    let _ = ready.send(None);
                }
            }
            unsafe { CoUninitialize() };
        })
        .map_err(|_| "capture_failed")?;
    let running = Running { stop, thread: Some(thread) };
    match opened.recv() {
        Ok(Some(rate)) => Ok((rate, Box::new(running))),
        _ => Err("capture_failed"),
    }
}

impl Loopback {
    unsafe fn open() -> windows::core::Result<Loopback> {
        unsafe {
            let devices: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)?;
            let output = devices.GetDefaultAudioEndpoint(eRender, eConsole)?;
            let client: IAudioClient = output.Activate(CLSCTX_ALL, None)?;
            let format = client.GetMixFormat()?;
            let mix: WAVEFORMATEX = *format;
            let tag = u32::from(mix.wFormatTag);
            let (float, mask) = if tag == WAVE_FORMAT_EXTENSIBLE {
                let extensible: WAVEFORMATEXTENSIBLE = *format.cast::<WAVEFORMATEXTENSIBLE>();
                let sub = extensible.SubFormat;
                (sub == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT, extensible.dwChannelMask)
            } else {
                (tag == WAVE_FORMAT_IEEE_FLOAT, 0)
            };
            let bits = mix.wBitsPerSample;
            let sample = match (float, bits) {
                (true, 32) => Some(Sample::Float),
                (false, 16) => Some(Sample::Int16),
                (false, 32) => Some(Sample::Int32),
                _ => None,
            };
            // A 200 ms buffer, read every 10 ms.
            let initialized =
                client.Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, 2_000_000, 0, format, None);
            CoTaskMemFree(Some(format.cast_const().cast()));
            initialized?;
            let Some(sample) = sample else {
                return Err(windows::core::Error::new(
                    windows::Win32::Foundation::E_NOTIMPL,
                    format!("the mix is {bits} bits, float {float}"),
                ));
            };
            let capture: IAudioCaptureClient = client.GetService()?;
            client.Start()?;
            let channels = usize::from(mix.nChannels.max(1));
            // Front left, right and center: the center is the third channel.
            let center = (channels >= 3 && mask & 0b111 == 0b111).then_some(2);
            Ok(Loopback { client, capture, rate: mix.nSamplesPerSec, channels, center, sample })
        }
    }

    /// Reads until `stop`, handing the frames over as stereo. The loopback
    /// sends nothing while nothing plays, so silence is made up to keep time.
    unsafe fn run(&self, sink: &Sink, stop: &AtomicBool) -> windows::core::Result<()> {
        let started = Instant::now();
        let mut handed: u64 = 0;
        let margin = u64::from(self.rate) / 10;
        while !stop.load(Ordering::Relaxed) {
            std::thread::sleep(Duration::from_millis(10));
            loop {
                let waiting = unsafe { self.capture.GetNextPacketSize()? };
                if waiting == 0 {
                    break;
                }
                let (mut data, mut frames, mut flags) = (std::ptr::null_mut(), 0_u32, 0_u32);
                unsafe { self.capture.GetBuffer(&mut data, &mut frames, &mut flags, None, None)? };
                let stereo = if flags & (AUDCLNT_BUFFERFLAGS_SILENT.0 as u32) != 0 || data.is_null() {
                    vec![0.0; frames as usize * 2]
                } else {
                    unsafe { self.stereo(data, frames as usize) }
                };
                unsafe { self.capture.ReleaseBuffer(frames)? };
                handed += u64::from(frames);
                if sink.send(stereo).is_err() {
                    return Ok(());
                }
            }
            let due = (started.elapsed().as_secs_f64() * f64::from(self.rate)) as u64;
            if due > handed + margin {
                let missing = due - handed - margin / 2;
                handed += missing;
                if sink.send(vec![0.0; missing as usize * 2]).is_err() {
                    return Ok(());
                }
            }
        }
        Ok(())
    }

    unsafe fn stereo(&self, data: *const u8, frames: usize) -> Vec<f32> {
        let count = frames * self.channels;
        let samples: Vec<f32> = match self.sample {
            Sample::Float => unsafe { std::slice::from_raw_parts(data.cast::<f32>(), count) }.to_vec(),
            Sample::Int16 => unsafe { std::slice::from_raw_parts(data.cast::<i16>(), count) }
                .iter()
                .map(|sample| f32::from(*sample) / 32768.0)
                .collect(),
            Sample::Int32 => unsafe { std::slice::from_raw_parts(data.cast::<i32>(), count) }
                .iter()
                .map(|sample| *sample as f32 / 2_147_483_648.0)
                .collect(),
        };
        let mut stereo = Vec::with_capacity(frames * 2);
        for frame in samples.chunks_exact(self.channels) {
            let center = self.center.map_or(0.0, |at| frame[at] * std::f32::consts::FRAC_1_SQRT_2);
            let left = frame[0];
            let right = if self.channels > 1 { frame[1] } else { left };
            stereo.extend_from_slice(&[left + center, right + center]);
        }
        stereo
    }
}

/// Encodes a 16-bit WAV as AAC (128 kbit/s) in an M4A with Media
/// Foundation; false where it cannot (its encoder takes 44.1 and 48 kHz).
pub(super) fn encode(wav: &Path, m4a: &Path) -> bool {
    let _ = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
    let started = unsafe { MFStartup(MF_VERSION, MFSTARTUP_FULL) };
    let encoded = started.and_then(|_| unsafe { encode_started(wav, m4a) });
    if let Err(error) = &encoded {
        log::error!("capture: encoding {}: {error}", wav.display());
    }
    unsafe {
        let _ = MFShutdown();
        CoUninitialize();
    }
    encoded.is_ok()
}

unsafe fn encode_started(wav: &Path, m4a: &Path) -> windows::core::Result<()> {
    use std::io::{Read, Seek, SeekFrom};
    let failed = |what: String| windows::core::Error::new(windows::Win32::Foundation::E_FAIL, what);
    let mut file = std::fs::File::open(wav).map_err(|error| failed(error.to_string()))?;
    let info = wav_info(&mut file).map_err(|error| failed(error.to_string()))?;
    if !matches!(info.rate, 44_100 | 48_000) || info.bits != 16 {
        return Err(failed(format!("{} Hz is not one the AAC encoder takes", info.rate)));
    }
    let channels = u32::from(info.channels);
    let block = channels * 2;
    unsafe {
        let writer: IMFSinkWriter = MFCreateSinkWriterFromURL(&HSTRING::from(m4a.as_os_str()), None, None)?;
        let output = MFCreateMediaType()?;
        output.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Audio)?;
        output.SetGUID(&MF_MT_SUBTYPE, &MFAudioFormat_AAC)?;
        output.SetUINT32(&MF_MT_AUDIO_BITS_PER_SAMPLE, 16)?;
        output.SetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND, info.rate)?;
        output.SetUINT32(&MF_MT_AUDIO_NUM_CHANNELS, channels)?;
        output.SetUINT32(&MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 16_000)?;
        let stream = writer.AddStream(&output)?;
        let input = MFCreateMediaType()?;
        input.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Audio)?;
        input.SetGUID(&MF_MT_SUBTYPE, &MFAudioFormat_PCM)?;
        input.SetUINT32(&MF_MT_AUDIO_BITS_PER_SAMPLE, 16)?;
        input.SetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND, info.rate)?;
        input.SetUINT32(&MF_MT_AUDIO_NUM_CHANNELS, channels)?;
        input.SetUINT32(&MF_MT_AUDIO_BLOCK_ALIGNMENT, block)?;
        input.SetUINT32(&MF_MT_AUDIO_AVG_BYTES_PER_SECOND, info.rate * block)?;
        writer.SetInputMediaType(stream, &input, None)?;
        writer.BeginWriting()?;
        file.seek(SeekFrom::Start(info.data_at)).map_err(|error| failed(error.to_string()))?;
        // A second at a time; times in 100 ns.
        let chunk = (info.rate * block) as usize;
        let mut bytes = vec![0; chunk];
        let (mut left, mut frames_done) = (info.data_len, 0_u64);
        while left > 0 {
            let take = left.min(chunk as u64) as usize;
            file.read_exact(&mut bytes[..take]).map_err(|error| failed(error.to_string()))?;
            let buffer = MFCreateMemoryBuffer(take as u32)?;
            let mut into = std::ptr::null_mut();
            buffer.Lock(&mut into, None, None)?;
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), into, take);
            buffer.Unlock()?;
            buffer.SetCurrentLength(take as u32)?;
            let sample = MFCreateSample()?;
            sample.AddBuffer(&buffer)?;
            let frames = take as u64 / u64::from(block);
            sample.SetSampleTime((frames_done * 10_000_000 / u64::from(info.rate)) as i64)?;
            sample.SetSampleDuration((frames * 10_000_000 / u64::from(info.rate)) as i64)?;
            writer.WriteSample(stream, &sample)?;
            frames_done += frames;
            left -= take as u64;
        }
        writer.Finalize()
    }
}
