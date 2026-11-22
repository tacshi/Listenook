//! A Core Audio process tap of every app but this one, mixed to stereo
//! (macOS 14.2 and later), read through a private aggregate device clocked
//! by the system's output. The tap functions are looked up when used, so
//! the app still opens on macOS 14.0.

#![allow(non_upper_case_globals, non_snake_case, clippy::missing_transmute_annotations)]

use std::{
    ffi::{CStr, CString, c_char, c_void},
    path::Path,
    sync::{Mutex, mpsc},
    time::Duration,
};

use super::{Access, Sink, Stream};

type Id = *mut c_void;
type Sel = *const c_void;
type CFTypeRef = *const c_void;
type CFStringRef = *const c_void;
type CFMutableDictionaryRef = *mut c_void;
type CFMutableArrayRef = *mut c_void;
type OSStatus = i32;
type AudioObjectID = u32;

#[repr(C)]
struct PropertyAddress {
    selector: u32,
    scope: u32,
    element: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct StreamDescription {
    sample_rate: f64,
    format_id: u32,
    format_flags: u32,
    bytes_per_packet: u32,
    frames_per_packet: u32,
    bytes_per_frame: u32,
    channels_per_frame: u32,
    bits_per_channel: u32,
    reserved: u32,
}

#[repr(C)]
struct AudioBuffer {
    channels: u32,
    bytes: u32,
    data: *mut c_void,
}

#[repr(C)]
struct AudioBufferList {
    count: u32,
    buffers: [AudioBuffer; 1],
}

type IoProc = unsafe extern "C" fn(
    AudioObjectID,
    *const c_void,
    *const AudioBufferList,
    *const c_void,
    *mut AudioBufferList,
    *const c_void,
    *mut c_void,
) -> OSStatus;

const fn code(name: &[u8; 4]) -> u32 {
    u32::from_be_bytes(*name)
}

const SYSTEM_OBJECT: AudioObjectID = 1;
const SCOPE_GLOBAL: u32 = code(b"glob");
const PID_TO_PROCESS: u32 = code(b"id2p");
const DEFAULT_SYSTEM_OUTPUT: u32 = code(b"sOut");
const DEVICE_UID: u32 = code(b"uid ");
const TAP_FORMAT: u32 = code(b"tfmt");
const NOMINAL_RATE: u32 = code(b"nsrt");
const FORMAT_IS_FLOAT: u32 = 1;
const UTF8: u32 = 0x0800_0100;

#[link(name = "CoreAudio", kind = "framework")]
unsafe extern "C" {
    fn AudioObjectGetPropertyData(
        object: AudioObjectID,
        address: *const PropertyAddress,
        qualifier_size: u32,
        qualifier: *const c_void,
        size: *mut u32,
        data: *mut c_void,
    ) -> OSStatus;
    fn AudioHardwareCreateAggregateDevice(description: CFTypeRef, device: *mut AudioObjectID) -> OSStatus;
    fn AudioHardwareDestroyAggregateDevice(device: AudioObjectID) -> OSStatus;
    fn AudioDeviceCreateIOProcID(
        device: AudioObjectID,
        proc_: IoProc,
        client: *mut c_void,
        id: *mut *mut c_void,
    ) -> OSStatus;
    fn AudioDeviceDestroyIOProcID(device: AudioObjectID, id: *mut c_void) -> OSStatus;
    fn AudioDeviceStart(device: AudioObjectID, id: *mut c_void) -> OSStatus;
    fn AudioDeviceStop(device: AudioObjectID, id: *mut c_void) -> OSStatus;
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFBooleanTrue: CFTypeRef;
    static kCFBooleanFalse: CFTypeRef;
    static kCFTypeDictionaryKeyCallBacks: c_void;
    static kCFTypeDictionaryValueCallBacks: c_void;
    static kCFTypeArrayCallBacks: c_void;
    fn CFStringCreateWithCString(allocator: CFTypeRef, text: *const c_char, encoding: u32) -> CFStringRef;
    fn CFDictionaryCreateMutable(
        allocator: CFTypeRef,
        capacity: isize,
        keys: *const c_void,
        values: *const c_void,
    ) -> CFMutableDictionaryRef;
    fn CFDictionarySetValue(dictionary: CFMutableDictionaryRef, key: CFTypeRef, value: CFTypeRef);
    fn CFArrayCreateMutable(allocator: CFTypeRef, capacity: isize, callbacks: *const c_void) -> CFMutableArrayRef;
    fn CFArrayAppendValue(array: CFMutableArrayRef, value: CFTypeRef);
    fn CFRelease(object: CFTypeRef);
}

#[link(name = "objc")]
unsafe extern "C" {
    fn objc_getClass(name: *const c_char) -> Id;
    fn sel_registerName(name: *const c_char) -> Sel;
    fn objc_msgSend();
    fn objc_autoreleasePoolPush() -> *mut c_void;
    fn objc_autoreleasePoolPop(pool: *mut c_void);
}

#[link(name = "Foundation", kind = "framework")]
unsafe extern "C" {}

unsafe extern "C" {
    fn dlopen(path: *const c_char, mode: i32) -> *mut c_void;
    fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
    fn getpid() -> i32;
    static _NSConcreteGlobalBlock: c_void;
}

const RTLD_LAZY: i32 = 1;
const RTLD_DEFAULT: *mut c_void = -2_isize as *mut c_void;

type CreateTap = unsafe extern "C" fn(Id, *mut AudioObjectID) -> OSStatus;
type DestroyTap = unsafe extern "C" fn(AudioObjectID) -> OSStatus;

fn symbol(handle: *mut c_void, name: &CStr) -> *mut c_void {
    unsafe { dlsym(handle, name.as_ptr()) }
}

fn tap_functions() -> Option<(CreateTap, DestroyTap)> {
    let create = symbol(RTLD_DEFAULT, c"AudioHardwareCreateProcessTap");
    let destroy = symbol(RTLD_DEFAULT, c"AudioHardwareDestroyProcessTap");
    if create.is_null() || destroy.is_null() || unsafe { objc_getClass(c"CATapDescription".as_ptr()) }.is_null() {
        return None;
    }
    Some(unsafe { (std::mem::transmute(create), std::mem::transmute(destroy)) })
}

pub(super) fn has_taps() -> bool {
    tap_functions().is_some()
}

// Whether other apps may be heard is the `kTCCServiceAudioCapture` service
// of TCC, which has no public call to read it: what the system answers is
// read the way Apple's own tools do, and when it cannot be, recording just
// starts (the system then asks by itself).

fn tcc() -> *mut c_void {
    unsafe { dlopen(c"/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC".as_ptr(), RTLD_LAZY) }
}

const SERVICE: &CStr = c"kTCCServiceAudioCapture";

pub(super) fn access() -> Access {
    let handle = tcc();
    let preflight = symbol(handle, c"TCCAccessPreflight");
    if preflight.is_null() {
        return Access::Unknown;
    }
    let preflight: unsafe extern "C" fn(CFStringRef, CFTypeRef) -> isize = unsafe { std::mem::transmute(preflight) };
    let service = cf_string(SERVICE);
    let answer = unsafe { preflight(service, std::ptr::null()) };
    unsafe { CFRelease(service) };
    match answer {
        0 => Access::Granted,
        1 => Access::Denied,
        _ => Access::Unknown,
    }
}

static ANSWER: Mutex<Option<mpsc::Sender<bool>>> = Mutex::new(None);

#[repr(C)]
struct BlockDescriptor {
    reserved: usize,
    size: usize,
}

#[repr(C)]
struct Block {
    isa: *const c_void,
    flags: i32,
    reserved: i32,
    invoke: unsafe extern "C" fn(*const Block, u8),
    descriptor: *const BlockDescriptor,
}

struct GlobalBlock(Block);

unsafe impl Sync for GlobalBlock {}

const BLOCK_IS_GLOBAL: i32 = 1 << 28;

static DESCRIPTOR: BlockDescriptor = BlockDescriptor { reserved: 0, size: std::mem::size_of::<Block>() };

unsafe extern "C" fn answered(_: *const Block, granted: u8) {
    if let Some(answer) = ANSWER.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).take() {
        let _ = answer.send(granted != 0);
    }
}

static ANSWERED: GlobalBlock = GlobalBlock(Block {
    isa: &raw const _NSConcreteGlobalBlock,
    flags: BLOCK_IS_GLOBAL,
    reserved: 0,
    invoke: answered,
    descriptor: &DESCRIPTOR,
});

pub(super) fn ask() -> bool {
    let request = symbol(tcc(), c"TCCAccessRequest");
    if request.is_null() {
        return true;
    }
    let request: unsafe extern "C" fn(CFStringRef, CFTypeRef, *const Block) = unsafe { std::mem::transmute(request) };
    let (answer, answered) = mpsc::channel();
    *ANSWER.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(answer);
    let service = cf_string(SERVICE);
    unsafe {
        request(service, std::ptr::null(), &ANSWERED.0);
        CFRelease(service);
    }
    answered.recv_timeout(Duration::from_secs(600)).unwrap_or(false)
}

fn cf_string(text: &CStr) -> CFStringRef {
    unsafe { CFStringCreateWithCString(std::ptr::null(), text.as_ptr(), UTF8) }
}

fn cf_text(text: &str) -> CFStringRef {
    let text = CString::new(text).unwrap_or_default();
    cf_string(&text)
}

unsafe fn send<R>(object: Id, name: &CStr) -> R {
    let f: unsafe extern "C" fn(Id, Sel) -> R = unsafe { std::mem::transmute(objc_msgSend as unsafe extern "C" fn()) };
    unsafe { f(object, sel_registerName(name.as_ptr())) }
}

unsafe fn send_with<A, R>(object: Id, name: &CStr, argument: A) -> R {
    let f: unsafe extern "C" fn(Id, Sel, A) -> R =
        unsafe { std::mem::transmute(objc_msgSend as unsafe extern "C" fn()) };
    unsafe { f(object, sel_registerName(name.as_ptr()), argument) }
}

/// A property of a Core Audio object; `T` is plain data (a number, a
/// pointer, a C struct), which all zeroes is a value of.
fn property<T: Copy>(object: AudioObjectID, selector: u32, qualifier: Option<&i32>) -> Option<T> {
    let address = PropertyAddress { selector, scope: SCOPE_GLOBAL, element: 0 };
    let mut value: T = unsafe { std::mem::zeroed() };
    let mut size = std::mem::size_of::<T>() as u32;
    let (qualifier_size, qualifier) = match qualifier {
        Some(pid) => (std::mem::size_of::<i32>() as u32, (pid as *const i32).cast()),
        None => (0, std::ptr::null()),
    };
    let status = unsafe {
        AudioObjectGetPropertyData(object, &address, qualifier_size, qualifier, &mut size, (&raw mut value).cast())
    };
    (status == 0).then_some(value)
}

/// What was set up, torn down in the reverse order however far it got.
struct Tap {
    destroy_tap: DestroyTap,
    tap: AudioObjectID,
    device: AudioObjectID,
    proc_id: *mut c_void,
    started: bool,
    sink: *mut Sink,
}

unsafe impl Send for Tap {}

impl Stream for Tap {}

impl Drop for Tap {
    fn drop(&mut self) {
        unsafe {
            if self.started {
                AudioDeviceStop(self.device, self.proc_id);
            }
            if !self.proc_id.is_null() {
                AudioDeviceDestroyIOProcID(self.device, self.proc_id);
            }
            if self.device != 0 {
                AudioHardwareDestroyAggregateDevice(self.device);
            }
            if self.tap != 0 {
                (self.destroy_tap)(self.tap);
            }
            if !self.sink.is_null() {
                drop(Box::from_raw(self.sink));
            }
        }
    }
}

/// Hands each cycle's frames to the sink as interleaved stereo.
unsafe extern "C" fn received(
    _: AudioObjectID,
    _: *const c_void,
    input: *const AudioBufferList,
    _: *const c_void,
    _: *mut AudioBufferList,
    _: *const c_void,
    client: *mut c_void,
) -> OSStatus {
    if input.is_null() || client.is_null() {
        return 0;
    }
    let sink = unsafe { &*client.cast::<Sink>() };
    let list = unsafe { &*input };
    let buffers = unsafe { std::slice::from_raw_parts(list.buffers.as_ptr(), list.count as usize) };
    let Some(first) = buffers.first().filter(|buffer| !buffer.data.is_null() && buffer.channels > 0) else {
        return 0;
    };
    let samples = |buffer: &AudioBuffer| unsafe {
        std::slice::from_raw_parts(buffer.data.cast::<f32>(), buffer.bytes as usize / std::mem::size_of::<f32>())
    };
    let mut stereo;
    if first.channels >= 2 {
        let channels = first.channels as usize;
        let interleaved = samples(first);
        stereo = Vec::with_capacity(interleaved.len() / channels * 2);
        for frame in interleaved.chunks_exact(channels) {
            stereo.extend_from_slice(&frame[..2]);
        }
    } else {
        let left = samples(first);
        let right = buffers.get(1).filter(|buffer| !buffer.data.is_null()).map(samples).unwrap_or(left);
        stereo = Vec::with_capacity(left.len() * 2);
        for (l, r) in left.iter().zip(right) {
            stereo.extend_from_slice(&[*l, *r]);
        }
    }
    let _ = sink.send(stereo);
    0
}

pub(super) fn open(sink: Sink) -> Result<(u32, Box<dyn Stream>), &'static str> {
    let (create_tap, destroy_tap) = tap_functions().ok_or("capture_unsupported")?;
    let pool = unsafe { objc_autoreleasePoolPush() };
    let opened = unsafe { set_up(create_tap, destroy_tap, sink) };
    unsafe { objc_autoreleasePoolPop(pool) };
    opened
}

unsafe fn set_up(
    create_tap: CreateTap,
    destroy_tap: DestroyTap,
    sink: Sink,
) -> Result<(u32, Box<dyn Stream>), &'static str> {
    let failed = |step: &str, status: OSStatus| {
        log::error!("capture: {step} failed ({status})");
        "capture_failed"
    };
    let mut tap = Tap {
        destroy_tap,
        tap: 0,
        device: 0,
        proc_id: std::ptr::null_mut(),
        started: false,
        sink: std::ptr::null_mut(),
    };
    unsafe {
        // Every app but this one, mixed to stereo, heard as it plays.
        let pid = getpid();
        let excluded = CFArrayCreateMutable(std::ptr::null(), 0, &kCFTypeArrayCallBacks);
        if let Some(own) = property::<AudioObjectID>(SYSTEM_OBJECT, PID_TO_PROCESS, Some(&pid)).filter(|id| *id != 0) {
            let number: Id = send_with(objc_getClass(c"NSNumber".as_ptr()), c"numberWithUnsignedInt:", own);
            CFArrayAppendValue(excluded, number);
        }
        let description: Id = send(objc_getClass(c"CATapDescription".as_ptr()), c"alloc");
        let description: Id = send_with(description, c"initStereoGlobalTapButExcludeProcesses:", excluded);
        CFRelease(excluded);
        if description.is_null() {
            return Err(failed("describing the tap", 0));
        }
        let uuid: Id = send(objc_getClass(c"NSUUID".as_ptr()), c"UUID");
        let _: () = send_with(description, c"setUUID:", uuid);
        let _: () = send_with(description, c"setPrivate:", true);
        let _: () = send_with(description, c"setMuteBehavior:", 0_isize);
        let name = cf_text("Listenook");
        let _: () = send_with(description, c"setName:", name);
        CFRelease(name);
        let tap_uid: Id = send(uuid, c"UUIDString");
        let status = create_tap(description, &mut tap.tap);
        let _: () = send(description, c"release");
        if status != 0 {
            return Err(failed("creating the tap", status));
        }
        let format: StreamDescription =
            property(tap.tap, TAP_FORMAT, None).ok_or_else(|| failed("reading the tap", 0))?;
        if format.format_flags & FORMAT_IS_FLOAT == 0 || format.bits_per_channel != 32 || format.sample_rate < 8000.0 {
            log::error!("capture: the tap's format is not 32-bit float ({:#x})", format.format_flags);
            return Err("capture_failed");
        }

        // A private device holding the tap, clocked by the system's output.
        let output: AudioObjectID =
            property(SYSTEM_OBJECT, DEFAULT_SYSTEM_OUTPUT, None).ok_or_else(|| failed("finding the output", 0))?;
        let output_uid: CFStringRef =
            property(output, DEVICE_UID, None).ok_or_else(|| failed("naming the output", 0))?;
        let device_uid = cf_text(&format!("app.capyvibe.listenook.capture.{}", uuid::Uuid::new_v4().simple()));
        let dictionary = || {
            CFDictionaryCreateMutable(
                std::ptr::null(),
                0,
                (&raw const kCFTypeDictionaryKeyCallBacks).cast(),
                (&raw const kCFTypeDictionaryValueCallBacks).cast(),
            )
        };
        let set = |dictionary: CFMutableDictionaryRef, key: &CStr, value: CFTypeRef| {
            let key = cf_string(key);
            CFDictionarySetValue(dictionary, key, value);
            CFRelease(key);
        };
        let sub_device = dictionary();
        set(sub_device, c"uid", output_uid);
        let sub_devices = CFArrayCreateMutable(std::ptr::null(), 0, &kCFTypeArrayCallBacks);
        CFArrayAppendValue(sub_devices, sub_device);
        let sub_tap = dictionary();
        set(sub_tap, c"uid", tap_uid);
        set(sub_tap, c"drift", kCFBooleanTrue);
        let taps = CFArrayCreateMutable(std::ptr::null(), 0, &kCFTypeArrayCallBacks);
        CFArrayAppendValue(taps, sub_tap);
        let device_name = cf_text("Listenook Recording");
        let aggregate = dictionary();
        set(aggregate, c"name", device_name);
        set(aggregate, c"uid", device_uid);
        set(aggregate, c"master", output_uid);
        set(aggregate, c"private", kCFBooleanTrue);
        set(aggregate, c"stacked", kCFBooleanFalse);
        set(aggregate, c"tapautostart", kCFBooleanFalse);
        set(aggregate, c"subdevices", sub_devices);
        set(aggregate, c"taps", taps);
        let status = AudioHardwareCreateAggregateDevice(aggregate, &mut tap.device);
        for made in [aggregate, taps, sub_tap, sub_devices, sub_device, device_name, device_uid, output_uid] {
            CFRelease(made);
        }
        if status != 0 {
            return Err(failed("making the recording device", status));
        }

        tap.sink = Box::into_raw(Box::new(sink));
        let status = AudioDeviceCreateIOProcID(tap.device, received, tap.sink.cast(), &mut tap.proc_id);
        if status != 0 {
            return Err(failed("listening to the recording device", status));
        }
        let status = AudioDeviceStart(tap.device, tap.proc_id);
        if status != 0 {
            return Err(failed("starting the recording device", status));
        }
        tap.started = true;
        // The tap says the rate the apps play at, but the device hands its
        // frames over at its own rate, its clock's (an output may run at
        // 32 kHz while the apps play at 48).
        let rate = property::<f64>(tap.device, NOMINAL_RATE, None).filter(|rate| *rate >= 8000.0);
        let rate = rate.unwrap_or(format.sample_rate).round() as u32;
        log::info!("capture: recording at {rate} Hz (the apps play at {} Hz)", format.sample_rate);
        Ok((rate, Box::new(tap)))
    }
}

/// Encodes a WAV as AAC in an M4A with the system's converter.
pub(super) fn encode(wav: &Path, m4a: &Path) -> bool {
    let converted = std::process::Command::new("/usr/bin/afconvert")
        .args(["-f", "m4af", "-d", "aac", "-b", "128000"])
        .arg(wav)
        .arg(m4a)
        .output();
    match converted {
        Ok(output) if output.status.success() && m4a.is_file() => true,
        Ok(output) => {
            log::error!("capture: afconvert: {}", String::from_utf8_lossy(&output.stderr).trim());
            false
        }
        Err(error) => {
            log::error!("capture: afconvert: {error}");
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn this_mac_has_taps() {
        assert!(has_taps(), "macOS 14.2 and later have audio taps");
    }

    /// Records the Mac for three seconds, the last two playing a 1 kHz
    /// tone, and checks it came in all along (silence too) and at the pitch
    /// played. Plays a sound and needs System Audio Recording allowed for
    /// what runs it, so it runs only when asked:
    /// `cargo test records_what_plays -- --ignored`.
    #[test]
    #[ignore]
    fn records_what_plays() {
        let tone = std::env::temp_dir().join(format!("listenook-tone-{}.wav", std::process::id()));
        let mut wav = listenook_core::capture::WavWriter::create(&tone, 44_100, 2).unwrap();
        let samples: Vec<i16> = (0..44_100 * 2)
            .flat_map(|frame| {
                let sample = ((frame as f32 * 1000.0 / 44_100.0 * std::f32::consts::TAU).sin() * 6000.0) as i16;
                [sample, sample]
            })
            .collect();
        wav.write(&samples).unwrap();
        wav.finish().unwrap();

        let (sink, frames) = mpsc::channel();
        let (rate, stream) = open(sink).expect("the tap opens");
        std::thread::sleep(Duration::from_secs(1));
        let player = std::process::Command::new("/usr/bin/afplay").arg(&tone).spawn().unwrap();
        std::thread::sleep(Duration::from_secs(2));
        drop(stream);
        let _ = { player }.wait();
        let _ = std::fs::remove_file(&tone);
        let left: Vec<f32> = frames.into_iter().flatten().step_by(2).collect();
        let seconds = left.len() as f64 / f64::from(rate);
        assert!(seconds > 2.5, "frames came in for {seconds:.2} s of 3 s");
        let played: Vec<f32> =
            left.iter().copied().skip_while(|sample| sample.abs() < 0.05).take(rate as usize).collect();
        assert!(played.len() == rate as usize, "nothing was heard: is System Audio Recording allowed?");
        let rises = played.windows(2).filter(|pair| pair[0] < 0.0 && pair[1] >= 0.0).count();
        assert!((980..=1020).contains(&rises), "a 1 kHz tone came in at {rises} Hz at {rate} Hz");
    }
}
