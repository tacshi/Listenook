//! Apple's player shows AV1 only on chips that decode it (M3, A17 Pro and later) and VP9 only
//! once its decoder is asked for. Elsewhere AV1 pictures are converted: rav1d decodes them and
//! VideoToolbox's HEVC encoder codes them again, at most 1920 by 1080.

use std::ffi::{c_char, c_void};
use std::ptr::{NonNull, null, null_mut};
use std::sync::{Arc, Mutex, OnceLock};

use listenook_core::media::container::{Codec, Coding, Converted, Converter, Device, PICTURE_TIMESCALE};
use rav1d::include::dav1d::data::Dav1dData;
use rav1d::include::dav1d::dav1d::{Dav1dContext, Dav1dSettings};
use rav1d::include::dav1d::headers::DAV1D_PIXEL_LAYOUT_I420;
use rav1d::include::dav1d::picture::Dav1dPicture;
use rav1d::src::lib as dav1d;

type CFTypeRef = *const c_void;
type OSStatus = i32;

const AV1: u32 = u32::from_be_bytes(*b"av01");
const VP9: u32 = u32::from_be_bytes(*b"vp09");
const HEVC: u32 = u32::from_be_bytes(*b"hvc1");
const PLANAR: u32 = u32::from_be_bytes(*b"y420");
const PLANAR_FULL_RANGE: u32 = u32::from_be_bytes(*b"f420");

#[repr(C)]
#[derive(Clone, Copy)]
struct CMTime {
    value: i64,
    timescale: i32,
    flags: u32,
    epoch: i64,
}

const NO_TIME: CMTime = CMTime { value: 0, timescale: 0, flags: 0, epoch: 0 };

#[repr(C)]
struct CMVideoDimensions {
    width: i32,
    height: i32,
}

type OutputCallback = unsafe extern "C" fn(*mut c_void, *mut c_void, OSStatus, u32, CFTypeRef);

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFTypeDictionaryKeyCallBacks: c_void;
    static kCFTypeDictionaryValueCallBacks: c_void;
    static kCFBooleanFalse: CFTypeRef;
    fn CFRelease(value: CFTypeRef);
    fn CFNumberCreate(allocator: CFTypeRef, kind: isize, value: *const c_void) -> CFTypeRef;
    fn CFDictionaryCreate(
        allocator: CFTypeRef,
        keys: *const CFTypeRef,
        values: *const CFTypeRef,
        count: isize,
        key_callbacks: *const c_void,
        value_callbacks: *const c_void,
    ) -> CFTypeRef;
    fn CFDictionaryGetValue(dictionary: CFTypeRef, key: CFTypeRef) -> CFTypeRef;
    fn CFStringCreateWithCString(allocator: CFTypeRef, text: *const c_char, encoding: u32) -> CFTypeRef;
    fn CFDataGetLength(data: CFTypeRef) -> isize;
    fn CFDataGetBytePtr(data: CFTypeRef) -> *const u8;
    fn CFArrayGetCount(array: CFTypeRef) -> isize;
    fn CFArrayGetValueAtIndex(array: CFTypeRef, index: isize) -> CFTypeRef;
}

#[link(name = "CoreVideo", kind = "framework")]
unsafe extern "C" {
    static kCVPixelBufferPixelFormatTypeKey: CFTypeRef;
    static kCVPixelBufferWidthKey: CFTypeRef;
    static kCVPixelBufferHeightKey: CFTypeRef;
    static kCVPixelBufferIOSurfacePropertiesKey: CFTypeRef;
    static kCVImageBufferColorPrimariesKey: CFTypeRef;
    static kCVImageBufferColorPrimaries_ITU_R_709_2: CFTypeRef;
    static kCVImageBufferTransferFunctionKey: CFTypeRef;
    static kCVImageBufferTransferFunction_ITU_R_709_2: CFTypeRef;
    static kCVImageBufferYCbCrMatrixKey: CFTypeRef;
    static kCVImageBufferYCbCrMatrix_ITU_R_709_2: CFTypeRef;
    fn CVPixelBufferPoolCreate(
        allocator: CFTypeRef,
        pool_attributes: CFTypeRef,
        buffer_attributes: CFTypeRef,
        pool: *mut CFTypeRef,
    ) -> i32;
    fn CVPixelBufferPoolCreatePixelBuffer(allocator: CFTypeRef, pool: CFTypeRef, buffer: *mut CFTypeRef) -> i32;
    fn CVPixelBufferLockBaseAddress(buffer: CFTypeRef, flags: u64) -> i32;
    fn CVPixelBufferUnlockBaseAddress(buffer: CFTypeRef, flags: u64) -> i32;
    fn CVPixelBufferGetBaseAddressOfPlane(buffer: CFTypeRef, plane: usize) -> *mut u8;
    fn CVPixelBufferGetBytesPerRowOfPlane(buffer: CFTypeRef, plane: usize) -> usize;
    fn CVBufferSetAttachment(buffer: CFTypeRef, key: CFTypeRef, value: CFTypeRef, mode: u32);
}

#[link(name = "CoreMedia", kind = "framework")]
unsafe extern "C" {
    static kCMSampleAttachmentKey_NotSync: CFTypeRef;
    static kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: CFTypeRef;
    fn CMSampleBufferGetDataBuffer(sample: CFTypeRef) -> CFTypeRef;
    fn CMBlockBufferGetDataLength(block: CFTypeRef) -> usize;
    fn CMBlockBufferCopyDataBytes(block: CFTypeRef, offset: usize, length: usize, into: *mut c_void) -> OSStatus;
    fn CMSampleBufferGetPresentationTimeStamp(sample: CFTypeRef) -> CMTime;
    fn CMSampleBufferGetFormatDescription(sample: CFTypeRef) -> CFTypeRef;
    fn CMSampleBufferGetSampleAttachmentsArray(sample: CFTypeRef, create: u8) -> CFTypeRef;
    fn CMFormatDescriptionGetExtension(description: CFTypeRef, key: CFTypeRef) -> CFTypeRef;
    fn CMVideoFormatDescriptionGetDimensions(description: CFTypeRef) -> CMVideoDimensions;
}

#[link(name = "VideoToolbox", kind = "framework")]
unsafe extern "C" {
    static kVTCompressionPropertyKey_RealTime: CFTypeRef;
    static kVTCompressionPropertyKey_AllowFrameReordering: CFTypeRef;
    static kVTCompressionPropertyKey_ProfileLevel: CFTypeRef;
    static kVTProfileLevel_HEVC_Main_AutoLevel: CFTypeRef;
    static kVTCompressionPropertyKey_AverageBitRate: CFTypeRef;
    static kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: CFTypeRef;
    fn VTIsHardwareDecodeSupported(codec: u32) -> u8;
    fn VTCompressionSessionCreate(
        allocator: CFTypeRef,
        width: i32,
        height: i32,
        codec: u32,
        encoder: CFTypeRef,
        source_attributes: CFTypeRef,
        data_allocator: CFTypeRef,
        output: Option<OutputCallback>,
        context: *mut c_void,
        session: *mut CFTypeRef,
    ) -> OSStatus;
    fn VTSessionSetProperty(session: CFTypeRef, key: CFTypeRef, value: CFTypeRef) -> OSStatus;
    fn VTCompressionSessionEncodeFrame(
        session: CFTypeRef,
        image: CFTypeRef,
        shown: CMTime,
        duration: CMTime,
        properties: CFTypeRef,
        context: *mut c_void,
        flags: *mut u32,
    ) -> OSStatus;
    fn VTCompressionSessionCompleteFrames(session: CFTypeRef, until: CMTime) -> OSStatus;
    fn VTCompressionSessionInvalidate(session: CFTypeRef);
}

unsafe extern "C" {
    fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
}

/// What this device's player shows. The VP9 and AV1 decoders Apple ships beside the system
/// are asked for first: VP9's is there from macOS 11 and iOS 26.2.
pub(super) fn device() -> Device {
    static DEVICE: OnceLock<Device> = OnceLock::new();
    *DEVICE.get_or_init(|| unsafe {
        // RTLD_DEFAULT: looked up at run time, as iOS 18 has no such function.
        let register = dlsym(-2_isize as *mut c_void, c"VTRegisterSupplementalVideoDecoderIfAvailable".as_ptr());
        if !register.is_null() {
            let register: unsafe extern "C" fn(u32) = std::mem::transmute(register);
            register(VP9);
            register(AV1);
        }
        let device = Device {
            shows_vp9: VTIsHardwareDecodeSupported(VP9) != 0,
            shows_av1: VTIsHardwareDecodeSupported(AV1) != 0,
            converts_av1: true,
        };
        log::info!("pictures shown here: {device:?}");
        device
    })
}

/// A Core Foundation object this code made, released when dropped.
struct Owned(CFTypeRef);

impl Drop for Owned {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { CFRelease(self.0) };
        }
    }
}

fn number_i32(value: i32) -> Owned {
    Owned(unsafe { CFNumberCreate(null(), 3, (&raw const value).cast()) })
}

fn number_f64(value: f64) -> Owned {
    Owned(unsafe { CFNumberCreate(null(), 6, (&raw const value).cast()) })
}

fn dictionary(pairs: &[(CFTypeRef, CFTypeRef)]) -> Owned {
    let (keys, values): (Vec<_>, Vec<_>) = pairs.iter().copied().unzip();
    Owned(unsafe {
        CFDictionaryCreate(
            null(),
            keys.as_ptr(),
            values.as_ptr(),
            pairs.len() as isize,
            &raw const kCFTypeDictionaryKeyCallBacks,
            &raw const kCFTypeDictionaryValueCallBacks,
        )
    })
}

/// What the encoder has given out, filled from its own threads.
#[derive(Default)]
struct Out {
    pictures: Vec<Converted>,
    coding: Option<Coding>,
    failure: Option<String>,
}

unsafe extern "C" fn encoded(context: *mut c_void, _: *mut c_void, status: OSStatus, _: u32, sample: CFTypeRef) {
    let out = unsafe { &*(context as *const Mutex<Out>) };
    let mut out = out.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if status != 0 || sample.is_null() {
        out.failure.get_or_insert_with(|| format!("the HEVC encoder failed ({status})"));
        return;
    }
    unsafe {
        let block = CMSampleBufferGetDataBuffer(sample);
        let mut data = vec![0_u8; CMBlockBufferGetDataLength(block)];
        if CMBlockBufferCopyDataBytes(block, 0, data.len(), data.as_mut_ptr().cast()) != 0 {
            out.failure.get_or_insert_with(|| "an HEVC picture that couldn't be read".into());
            return;
        }
        let time = CMSampleBufferGetPresentationTimeStamp(sample);
        let shown = (i128::from(time.value) * i128::from(PICTURE_TIMESCALE) / i128::from(time.timescale.max(1))) as u64;
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, 0);
        let not_sync = if attachments.is_null() || CFArrayGetCount(attachments) == 0 {
            null()
        } else {
            CFDictionaryGetValue(CFArrayGetValueAtIndex(attachments, 0), kCMSampleAttachmentKey_NotSync)
        };
        let sync = not_sync.is_null() || not_sync == kCFBooleanFalse;
        if out.coding.is_none() {
            out.coding = coding(CMSampleBufferGetFormatDescription(sample));
        }
        out.pictures.push(Converted { data, shown, sync });
    }
}

/// The `hvcC` record and size of the encoder's pictures.
unsafe fn coding(description: CFTypeRef) -> Option<Coding> {
    unsafe {
        let atoms =
            CMFormatDescriptionGetExtension(description, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
        if atoms.is_null() {
            return None;
        }
        let name = Owned(CFStringCreateWithCString(null(), c"hvcC".as_ptr(), 0x0800_0100));
        let record = CFDictionaryGetValue(atoms, name.0);
        if record.is_null() {
            return None;
        }
        let config = std::slice::from_raw_parts(CFDataGetBytePtr(record), CFDataGetLength(record) as usize).to_vec();
        let size = CMVideoFormatDescriptionGetDimensions(description);
        Some(Coding { codec: Codec::Hevc, config, width: size.width as u16, height: size.height as u16 })
    }
}

/// The size pictures are encoded at: at most 1920 by 1080 (or 1080 by 1920), even.
fn encoded_size(width: u32, height: u32) -> (u32, u32) {
    let (long, short) = (width.max(height) as f64, width.min(height) as f64);
    let scale = (1920.0 / long).min(1080.0 / short).min(1.0);
    let even = |side: u32| ((f64::from(side) * scale / 2.0).round() as u32 * 2).max(2);
    (even(width), even(height))
}

struct Encoder {
    session: Owned,
    /// Buffers for pictures of the size and range of the first one.
    pool: Owned,
    size: (u32, u32),
    full_range: bool,
}

impl Drop for Encoder {
    fn drop(&mut self) {
        unsafe { VTCompressionSessionInvalidate(self.session.0) };
    }
}

impl Encoder {
    fn new(width: u32, height: u32, full_range: bool, out: &Arc<Mutex<Out>>) -> Result<Encoder, String> {
        let (wide, high) = encoded_size(width, height);
        let mut session = null();
        let status = unsafe {
            VTCompressionSessionCreate(
                null(),
                wide as i32,
                high as i32,
                HEVC,
                null(),
                null(),
                null(),
                Some(encoded),
                Arc::as_ptr(out).cast_mut().cast(),
                &mut session,
            )
        };
        if status != 0 {
            return Err(format!("no HEVC encoder here ({status})"));
        }
        let session = Owned(session);
        // About 2.5 Mbit/s for 1080p at 30 pictures a second: plenty for people talking.
        let rate = number_i32((f64::from(wide * high) * 30.0 * 0.04) as i32);
        let key_frames = number_f64(2.0);
        unsafe {
            for (key, value) in [
                (kVTCompressionPropertyKey_RealTime, kCFBooleanFalse),
                (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
                (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel),
                (kVTCompressionPropertyKey_AverageBitRate, rate.0),
                (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, key_frames.0),
            ] {
                let status = VTSessionSetProperty(session.0, key, value);
                if status != 0 {
                    log::info!("an HEVC encoder setting was refused ({status})");
                }
            }
        }
        let (format, surface) =
            (number_i32(if full_range { PLANAR_FULL_RANGE } else { PLANAR } as i32), dictionary(&[]));
        let (wide_from, high_from) = (width, height);
        let (width, height) = (number_i32(width as i32), number_i32(height as i32));
        let attributes = unsafe {
            dictionary(&[
                (kCVPixelBufferPixelFormatTypeKey, format.0),
                (kCVPixelBufferWidthKey, width.0),
                (kCVPixelBufferHeightKey, height.0),
                (kCVPixelBufferIOSurfacePropertiesKey, surface.0),
            ])
        };
        let mut pool = null();
        if unsafe { CVPixelBufferPoolCreate(null(), null(), attributes.0, &mut pool) } != 0 {
            return Err("no picture buffers".into());
        }
        Ok(Encoder { session, pool: Owned(pool), size: (wide_from, high_from), full_range })
    }

    /// Copies a decoded picture into a buffer and hands it to the encoder.
    fn encode(&mut self, picture: &Dav1dPicture, shown: i64, full_range: bool) -> Result<(), String> {
        if (picture.p.w as u32, picture.p.h as u32) != self.size || full_range != self.full_range {
            return Err("AV1 pictures that change their size or range".into());
        }
        if picture.data.iter().any(Option::is_none) {
            return Err("an AV1 picture without its planes".into());
        }
        let mut buffer = null();
        if unsafe { CVPixelBufferPoolCreatePixelBuffer(null(), self.pool.0, &mut buffer) } != 0 {
            return Err("no picture buffer".into());
        }
        let buffer = Owned(buffer);
        unsafe {
            if CVPixelBufferLockBaseAddress(buffer.0, 0) != 0 {
                return Err("a picture buffer that couldn't be written".into());
            }
            let (width, height) = (picture.p.w as usize, picture.p.h as usize);
            for plane in 0..3 {
                let (wide, high) = if plane == 0 { (width, height) } else { (width.div_ceil(2), height.div_ceil(2)) };
                let into = CVPixelBufferGetBaseAddressOfPlane(buffer.0, plane);
                let into_row = CVPixelBufferGetBytesPerRowOfPlane(buffer.0, plane);
                let from = picture.data[plane].map_or(null(), |data| data.as_ptr().cast_const().cast::<u8>());
                let from_row = picture.stride[usize::from(plane > 0)];
                for row in 0..high {
                    let into = std::slice::from_raw_parts_mut(into.add(row * into_row), wide);
                    let start = from.offset(row as isize * from_row);
                    if picture.p.bpc == 8 {
                        into.copy_from_slice(std::slice::from_raw_parts(start, wide));
                    } else {
                        let shift = picture.p.bpc - 8;
                        let samples = std::slice::from_raw_parts(start.cast::<u16>(), wide);
                        for (into, sample) in into.iter_mut().zip(samples) {
                            *into = (sample >> shift).min(255) as u8;
                        }
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer.0, 0);
            for (key, value) in [
                (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
                (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
                (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
            ] {
                CVBufferSetAttachment(buffer.0, key, value, 1);
            }
            let time = CMTime { value: shown, timescale: PICTURE_TIMESCALE as i32, flags: 1, epoch: 0 };
            let status = VTCompressionSessionEncodeFrame(
                self.session.0,
                buffer.0,
                time,
                NO_TIME,
                null(),
                null_mut(),
                null_mut(),
            );
            if status != 0 {
                return Err(format!("the HEVC encoder refused a picture ({status})"));
            }
        }
        Ok(())
    }

    /// Waits for every picture handed over to come out. (Handing one over waits while the
    /// encoder holds as many as it takes, so decoded pictures don't pile up in memory.)
    fn finish(&mut self) {
        unsafe { VTCompressionSessionCompleteFrames(self.session.0, NO_TIME) };
    }
}

/// Converts AV1 pictures into HEVC ones.
pub(super) struct Av1ToHevc {
    decoder: Dav1dContext,
    encoder: Option<Encoder>,
    out: Arc<Mutex<Out>>,
}

const EAGAIN: i32 = -35;

impl Av1ToHevc {
    pub(super) fn new() -> Result<Av1ToHevc, String> {
        let mut settings = std::mem::MaybeUninit::<Dav1dSettings>::uninit();
        let mut decoder = None;
        unsafe {
            dav1d::dav1d_default_settings(NonNull::new_unchecked(settings.as_mut_ptr()));
            let result = dav1d::dav1d_open(NonNull::new(&raw mut decoder), NonNull::new(settings.as_mut_ptr()));
            if result.0 != 0 {
                return Err(format!("no AV1 decoder ({})", result.0));
            }
        }
        let decoder = decoder.ok_or("no AV1 decoder")?;
        Ok(Av1ToHevc { decoder, encoder: None, out: Arc::default() })
    }

    /// Encodes the pictures the decoder has ready.
    fn drain(&mut self) -> Result<(), String> {
        loop {
            let mut picture = Dav1dPicture::default();
            let result = unsafe { dav1d::dav1d_get_picture(Some(self.decoder), NonNull::new(&raw mut picture)) };
            if result.0 == EAGAIN {
                return Ok(());
            }
            if result.0 != 0 {
                return Err(format!("an AV1 picture that couldn't be decoded ({})", result.0));
            }
            let encoded = self.encode(&picture);
            unsafe { dav1d::dav1d_picture_unref(NonNull::new(&raw mut picture)) };
            encoded?;
        }
    }

    fn encode(&mut self, picture: &Dav1dPicture) -> Result<(), String> {
        if picture.p.layout != DAV1D_PIXEL_LAYOUT_I420 {
            return Err("AV1 pictures other than 4:2:0".into());
        }
        let full_range = picture.seq_hdr.is_some_and(|header| unsafe { header.as_ref() }.color_range != 0);
        if self.encoder.is_none() {
            self.encoder = Some(Encoder::new(picture.p.w as u32, picture.p.h as u32, full_range, &self.out)?);
        }
        let encoder = self.encoder.as_mut().ok_or("no encoder")?;
        encoder.encode(picture, picture.m.timestamp, full_range)
    }
}

impl Drop for Av1ToHevc {
    fn drop(&mut self) {
        self.encoder = None;
        let mut decoder = Some(self.decoder);
        unsafe { dav1d::dav1d_close(NonNull::new(&raw mut decoder)) };
    }
}

impl Converter for Av1ToHevc {
    fn convert(&mut self, data: &[u8], shown: u64) -> Result<(), String> {
        let mut input = Dav1dData::default();
        unsafe {
            let into = dav1d::dav1d_data_create(NonNull::new(&raw mut input), data.len());
            if into.is_null() {
                return Err("no room for an AV1 picture".into());
            }
            std::ptr::copy_nonoverlapping(data.as_ptr(), into, data.len());
        }
        input.m.timestamp = shown as i64;
        let result = loop {
            let result = unsafe { dav1d::dav1d_send_data(Some(self.decoder), NonNull::new(&raw mut input)) };
            if result.0 == EAGAIN {
                if let Err(error) = self.drain() {
                    break Err(error);
                }
                continue;
            }
            if result.0 != 0 {
                break Err(format!("an AV1 picture that couldn't be read ({})", result.0));
            }
            if input.sz == 0 {
                break self.drain();
            }
        };
        if input.sz > 0 {
            unsafe { dav1d::dav1d_data_unref(NonNull::new(&raw mut input)) };
        }
        result
    }

    fn converted(&mut self, last: bool) -> Result<Vec<Converted>, String> {
        if last {
            self.drain()?;
            if let Some(encoder) = &mut self.encoder {
                encoder.finish();
            }
        }
        let mut out = self.out.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(failure) = out.failure.take() {
            return Err(failure);
        }
        Ok(std::mem::take(&mut out.pictures))
    }

    fn coding(&self) -> Option<Coding> {
        let out = self.out.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        out.coding.clone()
    }
}

#[cfg(test)]
mod tests {
    use listenook_core::media::container::{Pictures, mkv_to_mp4};

    use super::*;

    fn convert(input: &str, output: &str) {
        let mut converter = Av1ToHevc::new().unwrap();
        let started = std::time::Instant::now();
        let (input, output) = (std::fs::File::open(input).unwrap(), std::fs::File::create(output).unwrap());
        mkv_to_mp4(input, output, Pictures::Convert(&mut converter), &mut |_| true).unwrap();
        println!("converted in {:.1?}", started.elapsed());
    }

    #[test]
    fn av1_pictures_become_hevc_ones() {
        let output = std::env::temp_dir().join(format!("listenook-{}.mp4", uuid::Uuid::new_v4().simple()));
        convert(
            concat!(env!("CARGO_MANIFEST_DIR"), "/crates/listenook-core/tests/data/av1-opus.mkv"),
            &output.to_string_lossy(),
        );
        let size = std::fs::metadata(&output).unwrap().len();
        let mut file = mp4::Mp4Reader::read_header(std::fs::File::open(&output).unwrap(), size).unwrap();
        let _ = std::fs::remove_file(&output);
        let track = &file.tracks()[&1];
        assert_eq!((track.width(), track.height()), (160, 90));
        assert_eq!(file.sample_count(1).unwrap(), 15);
        assert!(file.read_sample(1, 1).unwrap().unwrap().is_sync);
    }

    #[test]
    #[ignore = "needs AV1 (an AV1 MKV) and OUT"]
    fn an_av1_video_is_converted() {
        convert(&std::env::var("AV1").unwrap(), &std::env::var("OUT").unwrap());
    }

    #[test]
    fn pictures_are_encoded_at_most_1080p() {
        assert_eq!(encoded_size(3840, 2160), (1920, 1080));
        assert_eq!(encoded_size(2160, 3840), (1080, 1920));
        assert_eq!(encoded_size(1280, 720), (1280, 720));
        assert_eq!(encoded_size(3840, 1600), (1920, 800));
        assert_eq!(encoded_size(161, 91), (162, 92));
    }
}
