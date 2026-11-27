#![allow(clippy::missing_transmute_annotations)]

use std::ffi::{CString, c_char, c_void};
#[cfg(target_os = "ios")]
use std::sync::{
    Mutex, Once,
    atomic::{AtomicPtr, Ordering},
};

pub(super) type Id = *mut c_void;
pub(super) type Sel = *const c_void;

#[link(name = "objc")]
unsafe extern "C" {
    fn objc_getClass(name: *const c_char) -> Id;
    fn sel_registerName(name: *const c_char) -> Sel;
    pub(super) fn objc_msgSend();
    pub(super) fn objc_allocateClassPair(superclass: Id, name: *const c_char, extra: usize) -> Id;
    pub(super) fn objc_registerClassPair(class: Id);
    pub(super) fn class_addMethod(
        class: Id,
        name: Sel,
        implementation: unsafe extern "C" fn(),
        types: *const c_char,
    ) -> bool;
    static _dispatch_main_q: c_void;
    fn dispatch_async_f(queue: *const c_void, context: *mut c_void, work: extern "C" fn(*mut c_void));
}

#[link(name = "Foundation", kind = "framework")]
unsafe extern "C" {}

#[cfg(target_os = "macos")]
pub(super) fn set_dock_icon(visible: bool) {
    on_main(move || unsafe {
        let app = send(class(c"NSApplication"), c"sharedApplication");
        let policy = if visible { 0 } else { 1 };
        let current: unsafe extern "C" fn(Id, Sel) -> usize =
            std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        if current(app, sel(c"activationPolicy")) == policy {
            return;
        }
        send_usize(app, c"setActivationPolicy:", policy);
        send_usize(app, c"activateIgnoringOtherApps:", 1);
    });
}

/// Takes the key window out of full screen through AppKit, on the main queue. nsh's own request
/// runs while nsh applies a batch, and macOS then animated the window's old full-screen content
/// (longbridge/nsh#3494). From here it animates the content laid out at the new size while the
/// video is paused, but not always while it plays. nsh's fix (longbridge/nsh#3497) did it every
/// time: once a release has it, nsh's `set_mode` takes this one's place.
#[cfg(target_os = "macos")]
pub(super) fn leave_full_screen() {
    /// `NSWindowStyleMaskFullScreen`.
    const FULL_SCREEN: usize = 1 << 14;
    on_main(|| unsafe {
        let window = send(send(class(c"NSApplication"), c"sharedApplication"), c"keyWindow");
        if window.is_null() {
            return;
        }
        let mask: unsafe extern "C" fn(Id, Sel) -> usize = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        if mask(window, sel(c"styleMask")) & FULL_SCREEN != 0 {
            send_id(window, c"toggleFullScreen:", std::ptr::null_mut());
        }
    });
}

/// How long sound takes from the player to the ears on the current route: a
/// few milliseconds on the speaker, 150 or more on Bluetooth headphones.
#[cfg(target_os = "ios")]
pub(super) fn output_latency_ms() -> f64 {
    unsafe {
        let session = send(class(c"AVAudioSession"), c"sharedInstance");
        if session.is_null() {
            return 0.0;
        }
        (get_f64(session, c"outputLatency") * 1000.0).max(0.0)
    }
}

pub(super) fn on_main(work: impl FnOnce() + Send + 'static) {
    extern "C" fn run(context: *mut c_void) {
        let work = unsafe { Box::from_raw(context.cast::<Box<dyn FnOnce() + Send>>()) };
        work();
    }
    let boxed: Box<Box<dyn FnOnce() + Send>> = Box::new(Box::new(work));
    unsafe { dispatch_async_f(&raw const _dispatch_main_q, Box::into_raw(boxed).cast(), run) };
}

pub(super) unsafe fn class(name: &std::ffi::CStr) -> Id {
    unsafe { objc_getClass(name.as_ptr()) }
}
pub(super) unsafe fn sel(name: &std::ffi::CStr) -> Sel {
    unsafe { sel_registerName(name.as_ptr()) }
}
pub(super) unsafe fn send(object: Id, name: &std::ffi::CStr) -> Id {
    let f: unsafe extern "C" fn(Id, Sel) -> Id = unsafe { std::mem::transmute(objc_msgSend as unsafe extern "C" fn()) };
    unsafe { f(object, sel(name)) }
}
pub(super) unsafe fn send_id(object: Id, name: &std::ffi::CStr, a: Id) -> Id {
    let f: unsafe extern "C" fn(Id, Sel, Id) -> Id =
        unsafe { std::mem::transmute(objc_msgSend as unsafe extern "C" fn()) };
    unsafe { f(object, sel(name), a) }
}
pub(super) unsafe fn send_id_id(object: Id, name: &std::ffi::CStr, a: Id, b: *const c_void) -> Id {
    let f: unsafe extern "C" fn(Id, Sel, Id, *const c_void) -> Id =
        unsafe { std::mem::transmute(objc_msgSend as unsafe extern "C" fn()) };
    unsafe { f(object, sel(name), a, b) }
}
pub(super) unsafe fn send_f64(object: Id, name: &std::ffi::CStr, a: f64) -> Id {
    let f: unsafe extern "C" fn(Id, Sel, f64) -> Id =
        unsafe { std::mem::transmute(objc_msgSend as unsafe extern "C" fn()) };
    unsafe { f(object, sel(name), a) }
}
pub(super) unsafe fn get_f64(object: Id, name: &std::ffi::CStr) -> f64 {
    let f: unsafe extern "C" fn(Id, Sel) -> f64 =
        unsafe { std::mem::transmute(objc_msgSend as unsafe extern "C" fn()) };
    unsafe { f(object, sel(name)) }
}
pub(super) unsafe fn send_usize(object: Id, name: &std::ffi::CStr, a: usize) -> Id {
    let f: unsafe extern "C" fn(Id, Sel, usize) -> Id =
        unsafe { std::mem::transmute(objc_msgSend as unsafe extern "C" fn()) };
    unsafe { f(object, sel(name), a) }
}
pub(super) unsafe fn string(text: &str) -> Id {
    let text = CString::new(text.replace('\0', "")).unwrap_or_default();
    unsafe { send_id(class(c"NSString"), c"stringWithUTF8String:", text.as_ptr() as Id) }
}

#[cfg(target_os = "ios")]
#[link(name = "UniformTypeIdentifiers", kind = "framework")]
unsafe extern "C" {}

#[cfg(target_os = "ios")]
static PICKED: Mutex<Vec<String>> = Mutex::new(Vec::new());

#[cfg(target_os = "ios")]
pub(super) fn take_picked() -> Vec<String> {
    PICKED.lock().map(|mut picked| std::mem::take(&mut *picked)).unwrap_or_default()
}

#[cfg(target_os = "ios")]
extern "C" fn documents_picked(_: Id, _: Sel, _picker: Id, urls: Id) {
    unsafe {
        let count: unsafe extern "C" fn(Id, Sel) -> usize = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let utf8: unsafe extern "C" fn(Id, Sel) -> *const c_char =
            std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let mut paths = Vec::new();
        for index in 0..count(urls, sel(c"count")) {
            let path = send(send_usize(urls, c"objectAtIndex:", index), c"path");
            let text = if path.is_null() { std::ptr::null() } else { utf8(path, sel(c"UTF8String")) };
            if !text.is_null() {
                paths.push(std::ffi::CStr::from_ptr(text).to_string_lossy().into_owned());
            }
        }
        if let Ok(mut picked) = PICKED.lock() {
            picked.extend(paths);
        }
        super::wake();
    }
}

#[cfg(target_os = "ios")]
pub(super) fn copy_opened(from: &str, to: &std::path::Path) -> bool {
    unsafe {
        let asks: unsafe extern "C" fn(Id, Sel) -> bool = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let url = send_id(class(c"NSURL"), c"fileURLWithPath:", string(from));
        let scoped = !url.is_null() && asks(url, sel(c"startAccessingSecurityScopedResource"));
        let copied = std::fs::copy(from, to).is_ok();
        if scoped {
            send(url, c"stopAccessingSecurityScopedResource");
        }
        copied
    }
}

#[cfg(target_os = "ios")]
pub(super) fn pick_documents() {
    static DELEGATE: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
    static MADE: Once = Once::new();
    on_main(|| unsafe {
        MADE.call_once(|| {
            let made = objc_allocateClassPair(class(c"NSObject"), c"ListenookDocumentsPicked".as_ptr(), 0);
            class_addMethod(
                made,
                sel(c"documentPicker:didPickDocumentsAtURLs:"),
                std::mem::transmute(documents_picked as extern "C" fn(Id, Sel, Id, Id)),
                c"v@:@@".as_ptr(),
            );
            objc_registerClassPair(made);
            DELEGATE.store(send(send(made, c"alloc"), c"init"), Ordering::Release);
        });
        let with_flag: unsafe extern "C" fn(Id, Sel, Id, bool) -> Id =
            std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let flag: unsafe extern "C" fn(Id, Sel, bool) = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let asks: unsafe extern "C" fn(Id, Sel, Sel) -> bool =
            std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let is: unsafe extern "C" fn(Id, Sel) -> bool = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let count: unsafe extern "C" fn(Id, Sel) -> usize = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());

        let app = send(class(c"UIApplication"), c"sharedApplication");
        let scenes = send(send(app, c"connectedScenes"), c"allObjects");
        let mut window: Id = std::ptr::null_mut();
        for index in 0..count(scenes, sel(c"count")) {
            let scene = send_usize(scenes, c"objectAtIndex:", index);
            if !asks(scene, sel(c"respondsToSelector:"), sel(c"windows")) {
                continue;
            }
            let windows = send(scene, c"windows");
            for at in 0..count(windows, sel(c"count")) {
                let candidate = send_usize(windows, c"objectAtIndex:", at);
                if window.is_null() || is(candidate, sel(c"isKeyWindow")) {
                    window = candidate;
                }
            }
        }
        if window.is_null() {
            return;
        }
        let mut presenter = send(window, c"rootViewController");
        loop {
            let over = send(presenter, c"presentedViewController");
            if over.is_null() {
                break;
            }
            presenter = over;
        }
        if presenter.is_null() {
            return;
        }
        let any = send_id(class(c"UTType"), c"typeWithIdentifier:", string("public.item"));
        let types = send_id(class(c"NSArray"), c"arrayWithObject:", any);
        let picker = with_flag(
            send(class(c"UIDocumentPickerViewController"), c"alloc"),
            sel(c"initForOpeningContentTypes:asCopy:"),
            types,
            true,
        );
        flag(picker, sel(c"setAllowsMultipleSelection:"), true);
        send_id(picker, c"setDelegate:", DELEGATE.load(Ordering::Acquire));
        let present: unsafe extern "C" fn(Id, Sel, Id, bool, Id) =
            std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        present(presenter, sel(c"presentViewController:animated:completion:"), picker, true, std::ptr::null_mut());
        send(picker, c"release");
    });
}

#[cfg(target_os = "ios")]
unsafe extern "C" {
    fn class_getName(class: Id) -> *const c_char;
    fn object_getClass(object: Id) -> Id;
}

#[cfg(target_os = "ios")]
static HAS_FOCUS: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[cfg(target_os = "ios")]
extern "C" fn holds_focus(_: Id, _: Sel, _: Id) {
    HAS_FOCUS.store(true, Ordering::Release);
}

#[cfg(target_os = "ios")]
extern "C" fn can_take_keys(_: Id, _: Sel) -> bool {
    true
}

#[cfg(target_os = "ios")]
unsafe fn root_view(view: Id, depth: u8) -> Id {
    unsafe {
        if view.is_null() || depth > 10 {
            return std::ptr::null_mut();
        }
        let name = class_getName(object_getClass(view));
        if !name.is_null() && std::ffi::CStr::from_ptr(name).to_string_lossy().contains("RootView") {
            return view;
        }
        let count: unsafe extern "C" fn(Id, Sel) -> usize = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let children = send(view, c"subviews");
        for index in 0..count(children, sel(c"count")) {
            let found = root_view(send_usize(children, c"objectAtIndex:", index), depth + 1);
            if !found.is_null() {
                return found;
            }
        }
        std::ptr::null_mut()
    }
}

#[cfg(target_os = "ios")]
extern "C" fn refuses(_: Id, _: Sel, _: Id) -> bool {
    false
}

#[cfg(target_os = "ios")]
static SCROLL_TO_TOP_REFUSED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[cfg(target_os = "ios")]
pub(super) fn keep_scroll_on_status_bar_taps() {
    if SCROLL_TO_TOP_REFUSED.load(Ordering::Acquire) {
        return;
    }
    on_main(|| unsafe {
        if SCROLL_TO_TOP_REFUSED.load(Ordering::Acquire) {
            return;
        }
        let count: unsafe extern "C" fn(Id, Sel) -> usize = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let asks: unsafe extern "C" fn(Id, Sel, Sel) -> bool =
            std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let app = send(class(c"UIApplication"), c"sharedApplication");
        let scenes = send(send(app, c"connectedScenes"), c"allObjects");
        for index in 0..count(scenes, sel(c"count")) {
            let scene = send_usize(scenes, c"objectAtIndex:", index);
            if !asks(scene, sel(c"respondsToSelector:"), sel(c"windows")) {
                continue;
            }
            let windows = send(scene, c"windows");
            for at in 0..count(windows, sel(c"count")) {
                let delegate = scroll_delegate(send_usize(windows, c"objectAtIndex:", at), class(c"UIScrollView"), 0);
                if delegate.is_null() {
                    continue;
                }
                let target = object_getClass(delegate);
                class_addMethod(
                    target,
                    sel(c"scrollViewShouldScrollToTop:"),
                    std::mem::transmute(refuses as extern "C" fn(Id, Sel, Id) -> bool),
                    c"B@:@".as_ptr(),
                );
                SCROLL_TO_TOP_REFUSED.store(true, Ordering::Release);
                return;
            }
        }
    });
}

#[cfg(target_os = "ios")]
unsafe fn scroll_delegate(view: Id, scroll: Id, depth: u8) -> Id {
    unsafe {
        if view.is_null() || depth > 64 {
            return std::ptr::null_mut();
        }
        if object_getClass(view) == scroll {
            let delegate = send(view, c"delegate");
            if !delegate.is_null() {
                return delegate;
            }
        }
        let count: unsafe extern "C" fn(Id, Sel) -> usize = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let children = send(view, c"subviews");
        for index in 0..count(children, sel(c"count")) {
            let found = scroll_delegate(send_usize(children, c"objectAtIndex:", index), scroll, depth + 1);
            if !found.is_null() {
                return found;
            }
        }
        std::ptr::null_mut()
    }
}

#[cfg(target_os = "ios")]
pub(super) fn keep_keys() {
    static READY: Once = Once::new();
    on_main(|| unsafe {
        READY.call_once(|| {
            class_addMethod(
                class(c"UIResponder"),
                sel(c"listenookHoldsFocus:"),
                std::mem::transmute(holds_focus as extern "C" fn(Id, Sel, Id)),
                c"v@:@".as_ptr(),
            );
        });
        let app = send(class(c"UIApplication"), c"sharedApplication");
        HAS_FOCUS.store(false, Ordering::Release);
        let ask: unsafe extern "C" fn(Id, Sel, Sel, Id, Id, Id) -> bool =
            std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        ask(
            app,
            sel(c"sendAction:to:from:forEvent:"),
            sel(c"listenookHoldsFocus:"),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        );
        if HAS_FOCUS.load(Ordering::Acquire) {
            return;
        }
        let count: unsafe extern "C" fn(Id, Sel) -> usize = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let asks: unsafe extern "C" fn(Id, Sel, Sel) -> bool =
            std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let scenes = send(send(app, c"connectedScenes"), c"allObjects");
        for index in 0..count(scenes, sel(c"count")) {
            let scene = send_usize(scenes, c"objectAtIndex:", index);
            if !asks(scene, sel(c"respondsToSelector:"), sel(c"windows")) {
                continue;
            }
            let windows = send(scene, c"windows");
            for at in 0..count(windows, sel(c"count")) {
                let root = root_view(send_usize(windows, c"objectAtIndex:", at), 0);
                if root.is_null() {
                    continue;
                }
                static ALLOWED: Once = Once::new();
                ALLOWED.call_once(|| {
                    class_addMethod(
                        object_getClass(root),
                        sel(c"canBecomeFirstResponder"),
                        std::mem::transmute(can_take_keys as extern "C" fn(Id, Sel) -> bool),
                        c"B@:".as_ptr(),
                    );
                });
                send(root, c"becomeFirstResponder");
                return;
            }
        }
    });
}

/// The screen's brightness and the system volume (0..1, as `f32` bits) the
/// main thread last read, `u32::MAX` before it has: what a swipe on a video
/// starts from.
#[cfg(target_os = "ios")]
static LEVELS: [std::sync::atomic::AtomicU32; 2] =
    [std::sync::atomic::AtomicU32::new(u32::MAX), std::sync::atomic::AtomicU32::new(u32::MAX)];

/// The `MPVolumeView` whose slider sets the system volume, in the window while
/// a swipe lasts (which keeps the system's own volume indicator away).
#[cfg(target_os = "ios")]
static VOLUME_VIEW: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

#[cfg(target_os = "ios")]
#[repr(C)]
struct Rect {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

#[cfg(target_os = "ios")]
unsafe fn first_window() -> Id {
    unsafe {
        let count: unsafe extern "C" fn(Id, Sel) -> usize = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let asks: unsafe extern "C" fn(Id, Sel, Sel) -> bool =
            std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let app = send(class(c"UIApplication"), c"sharedApplication");
        let scenes = send(send(app, c"connectedScenes"), c"allObjects");
        for index in 0..count(scenes, sel(c"count")) {
            let scene = send_usize(scenes, c"objectAtIndex:", index);
            if !asks(scene, sel(c"respondsToSelector:"), sel(c"windows")) {
                continue;
            }
            let windows = send(scene, c"windows");
            if count(windows, sel(c"count")) > 0 {
                return send_usize(windows, c"objectAtIndex:", 0);
            }
        }
        std::ptr::null_mut()
    }
}

/// The slider inside the volume view.
#[cfg(target_os = "ios")]
unsafe fn volume_slider(view: Id) -> Id {
    unsafe {
        let count: unsafe extern "C" fn(Id, Sel) -> usize = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        let is_kind: unsafe extern "C" fn(Id, Sel, Id) -> bool =
            std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        send(view, c"layoutIfNeeded");
        let children = send(view, c"subviews");
        for index in 0..count(children, sel(c"count")) {
            let child = send_usize(children, c"objectAtIndex:", index);
            if is_kind(child, sel(c"isKindOfClass:"), class(c"UISlider")) {
                return child;
            }
        }
        std::ptr::null_mut()
    }
}

/// A swipe that may change the brightness or the volume begins: reads both
/// and puts the volume view in the window.
#[cfg(target_os = "ios")]
pub(super) fn begin_levels() {
    on_main(|| unsafe {
        let screen = send(class(c"UIScreen"), c"mainScreen");
        LEVELS[0].store((get_f64(screen, c"brightness") as f32).to_bits(), Ordering::Release);
        let session = send(class(c"AVAudioSession"), c"sharedInstance");
        if !session.is_null() {
            let volume: unsafe extern "C" fn(Id, Sel) -> f32 =
                std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
            LEVELS[1].store(volume(session, sel(c"outputVolume")).to_bits(), Ordering::Release);
        }
        let mut view = VOLUME_VIEW.load(Ordering::Acquire);
        if view.is_null() {
            let make: unsafe extern "C" fn(Id, Sel, Rect) -> Id =
                std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
            let allocated = send(class(c"MPVolumeView"), c"alloc");
            if allocated.is_null() {
                return;
            }
            view = make(allocated, sel(c"initWithFrame:"), Rect { x: -200.0, y: -200.0, width: 100.0, height: 40.0 });
            send_f64(view, c"setAlpha:", 0.01);
            VOLUME_VIEW.store(view, Ordering::Release);
        }
        let window = first_window();
        if !window.is_null() {
            send_id(window, c"addSubview:", view);
        }
    });
}

/// The brightness and the volume [`begin_levels`] read, once it has.
#[cfg(target_os = "ios")]
pub(super) fn levels() -> Option<(f32, f32)> {
    let read = |at: usize| {
        let bits = LEVELS[at].load(Ordering::Acquire);
        (bits != u32::MAX).then(|| f32::from_bits(bits))
    };
    Some((read(0)?, read(1)?))
}

#[cfg(target_os = "ios")]
pub(super) fn set_brightness(value: f32) {
    on_main(move || unsafe {
        send_f64(send(class(c"UIScreen"), c"mainScreen"), c"setBrightness:", value as f64);
    });
}

#[cfg(target_os = "ios")]
pub(super) fn set_volume(value: f32) {
    on_main(move || unsafe {
        let view = VOLUME_VIEW.load(Ordering::Acquire);
        if view.is_null() {
            return;
        }
        let slider = volume_slider(view);
        if slider.is_null() {
            return;
        }
        let set: unsafe extern "C" fn(Id, Sel, f32, bool) = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        set(slider, sel(c"setValue:animated:"), value, false);
        // UIControlEventValueChanged.
        send_usize(slider, c"sendActionsForControlEvents:", 1 << 12);
    });
}

/// The swipe ended: the volume view leaves the window, so the volume buttons
/// show the system's indicator again.
#[cfg(target_os = "ios")]
pub(super) fn end_levels() {
    on_main(|| unsafe {
        let view = VOLUME_VIEW.load(Ordering::Acquire);
        if !view.is_null() {
            send(view, c"removeFromSuperview");
        }
    });
}
