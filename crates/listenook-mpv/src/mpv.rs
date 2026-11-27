//! The part of libmpv's client API (`mpv/client.h`) the player uses, made safe: one handle,
//! usable from any thread, as libmpv allows.

use std::{
    ffi::{CStr, CString, c_char, c_double, c_int, c_void},
    ptr::{self, NonNull},
    sync::Mutex,
};

#[repr(C)]
struct RawEvent {
    event_id: c_int,
    error: c_int,
    reply_userdata: u64,
    data: *mut c_void,
}

#[repr(C)]
struct RawProperty {
    name: *const c_char,
    format: c_int,
    data: *mut c_void,
}

#[repr(C)]
struct RawEndFile {
    reason: c_int,
    error: c_int,
}

#[repr(C)]
struct RawHook {
    name: *const c_char,
    id: u64,
}

#[repr(C)]
struct RawLogMessage {
    prefix: *const c_char,
    level: *const c_char,
    text: *const c_char,
    log_level: c_int,
}

/// An `mpv_node`: a value of `format`.
#[repr(C)]
struct RawNode {
    value: RawNodeValue,
    format: c_int,
}

#[repr(C)]
#[derive(Clone, Copy)]
union RawNodeValue {
    int64: i64,
    list: *const RawNodeList,
    bytes: *const RawByteArray,
}

#[repr(C)]
struct RawNodeList {
    count: c_int,
    values: *const RawNode,
    keys: *const *const c_char,
}

#[repr(C)]
struct RawByteArray {
    data: *const u8,
    size: usize,
}

const FORMAT_FLAG: c_int = 3;
const FORMAT_INT64: c_int = 4;
const FORMAT_DOUBLE: c_int = 5;
const FORMAT_NODE_MAP: c_int = 8;
const FORMAT_BYTE_ARRAY: c_int = 9;

#[cfg_attr(windows, link(name = "libmpv-2", kind = "raw-dylib"))]
unsafe extern "C" {
    fn mpv_create() -> *mut c_void;
    fn mpv_initialize(handle: *mut c_void) -> c_int;
    fn mpv_terminate_destroy(handle: *mut c_void);
    fn mpv_set_option(handle: *mut c_void, name: *const c_char, format: c_int, data: *mut c_void) -> c_int;
    fn mpv_set_option_string(handle: *mut c_void, name: *const c_char, data: *const c_char) -> c_int;
    fn mpv_set_property(handle: *mut c_void, name: *const c_char, format: c_int, data: *mut c_void) -> c_int;
    fn mpv_set_property_string(handle: *mut c_void, name: *const c_char, data: *const c_char) -> c_int;
    fn mpv_get_property(handle: *mut c_void, name: *const c_char, format: c_int, data: *mut c_void) -> c_int;
    fn mpv_get_property_string(handle: *mut c_void, name: *const c_char) -> *mut c_char;
    fn mpv_free(data: *mut c_void);
    fn mpv_command_async(handle: *mut c_void, reply: u64, args: *const *const c_char) -> c_int;
    fn mpv_command_ret(handle: *mut c_void, args: *const *const c_char, result: *mut RawNode) -> c_int;
    fn mpv_free_node_contents(node: *mut RawNode);
    fn mpv_observe_property(handle: *mut c_void, reply: u64, name: *const c_char, format: c_int) -> c_int;
    fn mpv_request_log_messages(handle: *mut c_void, min_level: *const c_char) -> c_int;
    fn mpv_wait_event(handle: *mut c_void, timeout: c_double) -> *mut RawEvent;
    fn mpv_wakeup(handle: *mut c_void);
    fn mpv_hook_add(handle: *mut c_void, reply: u64, name: *const c_char, priority: c_int) -> c_int;
    fn mpv_hook_continue(handle: *mut c_void, id: u64) -> c_int;
    fn mpv_error_string(error: c_int) -> *const c_char;
}

/// Why a file stopped playing.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Ended {
    /// It played to its end (with `keep-open`, only when it has no video).
    Done,
    /// Another file replaced it, or it was stopped.
    Stopped,
    /// It could not be played: why.
    Failed(String),
}

/// A property the player observes, as it changed.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum Change {
    /// `time-pos`, seconds (`None`: no file).
    Position(Option<f64>),
    /// `duration`, seconds.
    Duration(Option<f64>),
    /// `pause`.
    Paused(bool),
    /// `paused-for-cache`: waiting for data.
    Waiting(bool),
    /// `eof-reached`: stopped at the end, the file kept open.
    AtEnd(bool),
}

/// What libmpv reported.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Event {
    /// Nothing within the time waited.
    Nothing,
    /// A file started loading.
    Starting,
    /// A file is loaded and starts playing.
    Loaded,
    /// Playback started again after a load or a seek: the picture there is shown.
    Restarted,
    Ended(Ended),
    Changed(Change),
    /// Shutting down: the handle is about to go.
    Shutdown,
    /// mpv waits in hook `before_playing` (`on_preloaded`: a file's tracks are known, nothing is
    /// decoded yet) until [`Mpv::resume`] with this id.
    BeforePlaying(u64),
    /// Anything else.
    Other,
}

/// The observed properties, by the id they are observed under.
const OBSERVED: [(&str, c_int); 5] = [
    ("time-pos", FORMAT_DOUBLE),
    ("duration", FORMAT_DOUBLE),
    ("pause", FORMAT_FLAG),
    ("paused-for-cache", FORMAT_FLAG),
    ("eof-reached", FORMAT_FLAG),
];

/// What every instance is started with: no config files, no terminal, and none of mpv's Lua
/// scripts, as the app draws its own controls. Each script runs LuaJIT, whose compiled code the
/// hardened runtime of a signed macOS app kills on its first run.
const BARE: [(&str, &str); 12] = [
    ("config", "no"),
    ("terminal", "no"),
    ("load-scripts", "no"),
    ("osc", "no"),
    ("ytdl", "no"),
    ("load-stats-overlay", "no"),
    ("load-console", "no"),
    ("load-auto-profiles", "no"),
    ("load-select", "no"),
    ("load-positioning", "no"),
    ("load-commands", "no"),
    ("load-context-menu", "no"),
];

/// An mpv instance. libmpv's functions may be called from any thread, except that
/// [`Self::wait_event`] is called by one thread at a time.
pub(crate) struct Mpv {
    handle: NonNull<c_void>,
    /// What mpv draws into, dropped only once mpv has stopped.
    _keep: Mutex<Box<dyn Send>>,
}

// SAFETY: the client API is thread-safe ("all functions can be called from any thread").
unsafe impl Send for Mpv {}
// SAFETY: as above; `wait_event` is only called from the player's event thread.
unsafe impl Sync for Mpv {}

pub(crate) fn c(text: &str) -> CString {
    CString::new(text.replace('\0', "")).expect("no NUL is left")
}

fn error(code: c_int) -> String {
    // SAFETY: mpv_error_string returns a static string for any code.
    unsafe { CStr::from_ptr(mpv_error_string(code)) }.to_string_lossy().into_owned()
}

pub(crate) fn checked(code: c_int) -> Result<(), String> {
    if code < 0 { Err(error(code)) } else { Ok(()) }
}

impl Mpv {
    /// A new instance with [`BARE`] and `options` (and `wid`, the native view it draws into, if any, which
    /// `keep` holds on to until mpv has stopped), started.
    pub(crate) fn start(options: &[(&str, &str)], wid: Option<i64>, keep: Box<dyn Send>) -> Result<Self, String> {
        // SAFETY: mpv_create has no preconditions; null means it failed.
        let handle = NonNull::new(unsafe { mpv_create() }).ok_or("libmpv could not start")?;
        let mpv = Mpv { handle, _keep: Mutex::new(keep) };
        if let Some(mut wid) = wid {
            let name = c("wid");
            // SAFETY: an INT64 option reads an i64 from `data`, during the call.
            checked(unsafe { mpv_set_option(mpv.raw(), name.as_ptr(), FORMAT_INT64, (&raw mut wid).cast()) })?;
        }
        for (name, value) in BARE.iter().chain(options) {
            let (name, value) = (c(name), c(value));
            // SAFETY: both are NUL-terminated and live through the call.
            let code = unsafe { mpv_set_option_string(mpv.raw(), name.as_ptr(), value.as_ptr()) };
            if code < 0 {
                log::warn!("mpv option {name:?}={value:?}: {}", error(code));
            }
        }
        // SAFETY: the handle is new and not initialized yet.
        checked(unsafe { mpv_initialize(mpv.raw()) })?;
        for (id, (name, format)) in (1..).zip(OBSERVED) {
            let name = c(name);
            // SAFETY: the name lives through the call.
            checked(unsafe { mpv_observe_property(mpv.raw(), id, name.as_ptr(), format) })?;
        }
        let level = c("warn");
        // SAFETY: the level lives through the call.
        checked(unsafe { mpv_request_log_messages(mpv.raw(), level.as_ptr()) })?;
        Ok(mpv)
    }

    pub(crate) fn raw(&self) -> *mut c_void {
        self.handle.as_ptr()
    }

    /// Runs `args` (`["seek", "4.2", "absolute+exact"]`) without waiting for it.
    pub(crate) fn command(&self, args: &[&str]) {
        let owned: Vec<CString> = args.iter().map(|arg| c(arg)).collect();
        let pointers: Vec<*const c_char> = owned.iter().map(|arg| arg.as_ptr()).chain([ptr::null()]).collect();
        // SAFETY: a NULL-terminated array of NUL-terminated strings, copied during the call.
        if let Err(why) = checked(unsafe { mpv_command_async(self.raw(), 0, pointers.as_ptr()) }) {
            log::warn!("mpv {args:?}: {why}");
        }
    }

    /// The picture shown, unscaled and without subtitles (`screenshot-raw video rgba`): its
    /// width, height and RGBA pixels, row by row. Waits for it.
    pub(crate) fn picture(&self) -> Option<(u32, u32, Vec<u8>)> {
        let owned = [c("screenshot-raw"), c("video"), c("rgba")];
        let pointers: Vec<*const c_char> = owned.iter().map(|arg| arg.as_ptr()).chain([ptr::null()]).collect();
        let mut result = RawNode { value: RawNodeValue { int64: 0 }, format: 0 };
        // SAFETY: a NULL-terminated array of NUL-terminated strings; mpv fills `result`.
        if let Err(why) = checked(unsafe { mpv_command_ret(self.raw(), pointers.as_ptr(), &raw mut result) }) {
            log::warn!("mpv screenshot-raw: {why}");
            return None;
        }
        // SAFETY: `result` is what mpv returned, read before it is freed.
        let picture = unsafe { rgba(&result) };
        // SAFETY: `result` was filled by mpv and is not used after this.
        unsafe { mpv_free_node_contents(&raw mut result) };
        picture
    }

    pub(crate) fn set_flag(&self, name: &str, value: bool) {
        let mut flag = c_int::from(value);
        self.set(name, FORMAT_FLAG, (&raw mut flag).cast());
    }

    /// Sets property `name` from its text form (`"1280x720"`, `"gpu"`).
    #[cfg_attr(target_os = "ios", allow(dead_code))]
    pub(crate) fn set_text(&self, name: &str, value: &str) {
        let (key, text) = (c(name), c(value));
        // SAFETY: both are NUL-terminated and live through the call.
        if let Err(why) = checked(unsafe { mpv_set_property_string(self.raw(), key.as_ptr(), text.as_ptr()) }) {
            log::warn!("mpv property {name}={value}: {why}");
        }
    }

    /// The native surface mpv draws into from now on (0: none).
    #[cfg(target_os = "android")]
    pub(crate) fn set_wid(&self, mut wid: i64) {
        let name = c("wid");
        // SAFETY: an INT64 option reads an i64 from `data`, during the call.
        if let Err(why) =
            checked(unsafe { mpv_set_option(self.raw(), name.as_ptr(), FORMAT_INT64, (&raw mut wid).cast()) })
        {
            log::warn!("mpv wid: {why}");
        }
    }

    pub(crate) fn set_number(&self, name: &str, value: f64) {
        let mut number = value;
        self.set(name, FORMAT_DOUBLE, (&raw mut number).cast());
    }

    fn set(&self, name: &str, format: c_int, data: *mut c_void) {
        let key = c(name);
        // SAFETY: `data` points to a value of `format`, read during the call.
        if let Err(why) = checked(unsafe { mpv_set_property(self.raw(), key.as_ptr(), format, data) }) {
            log::warn!("mpv property {name}: {why}");
        }
    }

    pub(crate) fn number(&self, name: &str) -> Option<f64> {
        let (key, mut value) = (c(name), 0.0_f64);
        // SAFETY: a DOUBLE property is written to `value`.
        let code = unsafe { mpv_get_property(self.raw(), key.as_ptr(), FORMAT_DOUBLE, (&raw mut value).cast()) };
        (code >= 0).then_some(value)
    }

    /// Property `name` as text.
    pub(crate) fn text(&self, name: &str) -> Option<String> {
        let key = c(name);
        // SAFETY: mpv returns a NUL-terminated string it allocated, or null; it is freed here.
        unsafe {
            let value = mpv_get_property_string(self.raw(), key.as_ptr());
            if value.is_null() {
                return None;
            }
            let text = CStr::from_ptr(value).to_string_lossy().into_owned();
            mpv_free(value.cast());
            Some(text)
        }
    }

    pub(crate) fn integer(&self, name: &str) -> Option<i64> {
        let (key, mut value) = (c(name), 0_i64);
        // SAFETY: an INT64 property is written to `value`.
        let code = unsafe { mpv_get_property(self.raw(), key.as_ptr(), FORMAT_INT64, (&raw mut value).cast()) };
        (code >= 0).then_some(value)
    }

    /// Has mpv wait at each file's `on_preloaded` hook ([`Event::BeforePlaying`]).
    pub(crate) fn pause_before_playing(&self) {
        let name = c("on_preloaded");
        // SAFETY: the name lives through the call.
        if let Err(why) = checked(unsafe { mpv_hook_add(self.raw(), 0, name.as_ptr(), 0) }) {
            log::warn!("mpv hook: {why}");
        }
    }

    /// Lets mpv go on from hook `id`.
    pub(crate) fn resume(&self, id: u64) {
        // SAFETY: an id mpv gave in a hook event.
        unsafe { mpv_hook_continue(self.raw(), id) };
    }

    /// Wakes a thread in [`Self::wait_event`].
    pub(crate) fn wake(&self) {
        // SAFETY: valid handle.
        unsafe { mpv_wakeup(self.raw()) }
    }

    /// The next event, waiting up to `timeout` seconds. One thread at a time.
    pub(crate) fn wait_event(&self, timeout: f64) -> Event {
        // SAFETY: the event stays valid until the next wait on this handle, and is read here.
        let event = unsafe { &*mpv_wait_event(self.raw(), timeout) };
        match event.event_id {
            0 => Event::Nothing,
            1 => Event::Shutdown,
            2 => {
                // SAFETY: a LOG_MESSAGE event carries an mpv_event_log_message.
                let message = unsafe { &*event.data.cast::<RawLogMessage>() };
                // SAFETY: its strings are NUL-terminated.
                let (prefix, text) = unsafe { (CStr::from_ptr(message.prefix), CStr::from_ptr(message.text)) };
                let level = if message.log_level <= 20 { log::Level::Error } else { log::Level::Warn };
                log::log!(level, "mpv {}: {}", prefix.to_string_lossy(), text.to_string_lossy().trim_end());
                Event::Other
            }
            6 => Event::Starting,
            7 => {
                // SAFETY: an END_FILE event carries an mpv_event_end_file.
                let end = unsafe { &*event.data.cast::<RawEndFile>() };
                Event::Ended(match end.reason {
                    0 => Ended::Done,
                    4 => Ended::Failed(error(end.error)),
                    _ => Ended::Stopped,
                })
            }
            8 => Event::Loaded,
            21 => Event::Restarted,
            25 => {
                // SAFETY: a HOOK event carries an mpv_event_hook.
                let hook = unsafe { &*event.data.cast::<RawHook>() };
                Event::BeforePlaying(hook.id)
            }
            22 => {
                // SAFETY: a PROPERTY_CHANGE event carries an mpv_event_property.
                let property = unsafe { &*event.data.cast::<RawProperty>() };
                Event::Changed(change(event.reply_userdata, property))
            }
            _ => Event::Other,
        }
    }
}

/// The picture in `screenshot-raw`'s result: a map of `w`, `h`, `stride` and `data`.
///
/// SAFETY: `node` is a node mpv returned, not freed yet.
unsafe fn rgba(node: &RawNode) -> Option<(u32, u32, Vec<u8>)> {
    if node.format != FORMAT_NODE_MAP {
        return None;
    }
    // SAFETY: a NODE_MAP holds a list of `count` values with as many keys.
    let list = unsafe { &*node.value.list };
    let count = usize::try_from(list.count).ok()?;
    let (mut width, mut height, mut stride, mut data) = (None, None, None, None);
    for at in 0..count {
        // SAFETY: both arrays have `count` entries; keys are NUL-terminated.
        let (key, value) = unsafe { (CStr::from_ptr(*list.keys.add(at)), &*list.values.add(at)) };
        match (key.to_bytes(), value.format) {
            // SAFETY: the format says which field of the union is set.
            (b"w", FORMAT_INT64) => width = Some(unsafe { value.value.int64 }),
            (b"h", FORMAT_INT64) => height = Some(unsafe { value.value.int64 }),
            (b"stride", FORMAT_INT64) => stride = Some(unsafe { value.value.int64 }),
            (b"data", FORMAT_BYTE_ARRAY) => data = Some(unsafe { &*value.value.bytes }),
            _ => {}
        }
    }
    let (width, height, stride) =
        (usize::try_from(width?).ok()?, usize::try_from(height?).ok()?, usize::try_from(stride?).ok()?);
    let data = data?;
    let row_bytes = width.checked_mul(4)?;
    let needed = height.checked_sub(1)?.checked_mul(stride)?.checked_add(row_bytes)?;
    if width == 0 || stride < row_bytes || data.size < needed {
        return None;
    }
    // SAFETY: mpv's byte array holds `size` bytes.
    let bytes = unsafe { std::slice::from_raw_parts(data.data, data.size) };
    let pixels = (0..height).flat_map(|row| &bytes[row * stride..row * stride + width * 4]).copied().collect();
    Some((u32::try_from(width).ok()?, u32::try_from(height).ok()?, pixels))
}

fn change(id: u64, property: &RawProperty) -> Change {
    // SAFETY: `data` is null (unavailable) or holds a value of the observed format.
    let flag = || !property.data.is_null() && unsafe { *property.data.cast::<c_int>() } != 0;
    // SAFETY: as above.
    let number = || (property.format == FORMAT_DOUBLE).then(|| unsafe { *property.data.cast::<f64>() });
    match id {
        1 => Change::Position(number()),
        2 => Change::Duration(number()),
        3 => Change::Paused(flag()),
        4 => Change::Waiting(flag()),
        _ => Change::AtEnd(flag()),
    }
}

impl Drop for Mpv {
    /// Stops mpv, which waits for its threads; `keep` goes after.
    fn drop(&mut self) {
        // SAFETY: the handle is not used after this.
        unsafe { mpv_terminate_destroy(self.raw()) }
    }
}
