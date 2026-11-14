#![allow(clippy::missing_transmute_annotations)]

use std::{
    ffi::{CString, c_char, c_void},
    sync::{
        Mutex, Once,
        atomic::{AtomicPtr, Ordering},
    },
};

use super::media::{Command, Now};

type Id = *mut c_void;
type Sel = *const c_void;

#[link(name = "objc")]
unsafe extern "C" {
    fn objc_getClass(name: *const c_char) -> Id;
    fn sel_registerName(name: *const c_char) -> Sel;
    fn objc_msgSend();
    fn objc_allocateClassPair(superclass: Id, name: *const c_char, extra: usize) -> Id;
    fn objc_registerClassPair(class: Id);
    fn class_addMethod(class: Id, name: Sel, implementation: unsafe extern "C" fn(), types: *const c_char) -> bool;
    static _dispatch_main_q: c_void;
    fn dispatch_async_f(queue: *const c_void, context: *mut c_void, work: extern "C" fn(*mut c_void));
}

#[link(name = "Foundation", kind = "framework")]
unsafe extern "C" {}

#[link(name = "MediaPlayer", kind = "framework")]
unsafe extern "C" {
    static MPMediaItemPropertyTitle: Id;
    static MPMediaItemPropertyArtist: Id;
    static MPMediaItemPropertyPlaybackDuration: Id;
    static MPNowPlayingInfoPropertyElapsedPlaybackTime: Id;
    static MPNowPlayingInfoPropertyPlaybackRate: Id;
}

static QUEUE: Mutex<Vec<Command>> = Mutex::new(Vec::new());

fn push(command: Command) {
    if let Ok(mut queue) = QUEUE.lock() {
        queue.push(command);
    }
}

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

pub(super) fn take() -> Vec<Command> {
    QUEUE.lock().map(|mut queue| std::mem::take(&mut *queue)).unwrap_or_default()
}

fn on_main(work: impl FnOnce() + Send + 'static) {
    extern "C" fn run(context: *mut c_void) {
        let work = unsafe { Box::from_raw(context.cast::<Box<dyn FnOnce() + Send>>()) };
        work();
    }
    let boxed: Box<Box<dyn FnOnce() + Send>> = Box::new(Box::new(work));
    unsafe { dispatch_async_f(&raw const _dispatch_main_q, Box::into_raw(boxed).cast(), run) };
}

unsafe fn class(name: &std::ffi::CStr) -> Id {
    unsafe { objc_getClass(name.as_ptr()) }
}
unsafe fn sel(name: &std::ffi::CStr) -> Sel {
    unsafe { sel_registerName(name.as_ptr()) }
}
unsafe fn send(object: Id, name: &std::ffi::CStr) -> Id {
    let f: unsafe extern "C" fn(Id, Sel) -> Id = unsafe { std::mem::transmute(objc_msgSend as unsafe extern "C" fn()) };
    unsafe { f(object, sel(name)) }
}
unsafe fn send_id(object: Id, name: &std::ffi::CStr, a: Id) -> Id {
    let f: unsafe extern "C" fn(Id, Sel, Id) -> Id =
        unsafe { std::mem::transmute(objc_msgSend as unsafe extern "C" fn()) };
    unsafe { f(object, sel(name), a) }
}
unsafe fn send_id_id(object: Id, name: &std::ffi::CStr, a: Id, b: *const c_void) -> Id {
    let f: unsafe extern "C" fn(Id, Sel, Id, *const c_void) -> Id =
        unsafe { std::mem::transmute(objc_msgSend as unsafe extern "C" fn()) };
    unsafe { f(object, sel(name), a, b) }
}
unsafe fn send_f64(object: Id, name: &std::ffi::CStr, a: f64) -> Id {
    let f: unsafe extern "C" fn(Id, Sel, f64) -> Id =
        unsafe { std::mem::transmute(objc_msgSend as unsafe extern "C" fn()) };
    unsafe { f(object, sel(name), a) }
}
unsafe fn get_f64(object: Id, name: &std::ffi::CStr) -> f64 {
    let f: unsafe extern "C" fn(Id, Sel) -> f64 =
        unsafe { std::mem::transmute(objc_msgSend as unsafe extern "C" fn()) };
    unsafe { f(object, sel(name)) }
}
unsafe fn send_usize(object: Id, name: &std::ffi::CStr, a: usize) -> Id {
    let f: unsafe extern "C" fn(Id, Sel, usize) -> Id =
        unsafe { std::mem::transmute(objc_msgSend as unsafe extern "C" fn()) };
    unsafe { f(object, sel(name), a) }
}
unsafe fn string(text: &str) -> Id {
    let text = CString::new(text.replace('\0', "")).unwrap_or_default();
    unsafe { send_id(class(c"NSString"), c"stringWithUTF8String:", text.as_ptr() as Id) }
}

extern "C" fn play(_: Id, _: Sel, _: Id) -> isize {
    push(Command::Play);
    0
}
extern "C" fn pause(_: Id, _: Sel, _: Id) -> isize {
    push(Command::Pause);
    0
}
extern "C" fn toggle(_: Id, _: Sel, _: Id) -> isize {
    push(Command::Toggle);
    0
}
extern "C" fn next(_: Id, _: Sel, _: Id) -> isize {
    push(Command::Next);
    0
}
extern "C" fn previous(_: Id, _: Sel, _: Id) -> isize {
    push(Command::Previous);
    0
}
extern "C" fn seek(_: Id, _: Sel, event: Id) -> isize {
    let seconds = unsafe { get_f64(event, c"positionTime") };
    push(Command::Seek((seconds * 1000.0) as i64));
    0
}

static TARGET: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

unsafe fn target() -> Id {
    static MADE: Once = Once::new();
    MADE.call_once(|| unsafe {
        let made = objc_allocateClassPair(class(c"NSObject"), c"ListenookSystemTarget".as_ptr(), 0);
        let methods: [(&std::ffi::CStr, extern "C" fn(Id, Sel, Id) -> isize); 6] = [
            (c"play:", play),
            (c"pause:", pause),
            (c"toggle:", toggle),
            (c"next:", next),
            (c"previous:", previous),
            (c"seek:", seek),
        ];
        for (name, method) in methods {
            class_addMethod(made, sel(name), std::mem::transmute(method), c"q@:@".as_ptr());
        }
        objc_registerClassPair(made);
        TARGET.store(send(send(made, c"alloc"), c"init"), Ordering::Release);
    });
    TARGET.load(Ordering::Acquire)
}

fn listen() {
    static LISTENING: Once = Once::new();
    LISTENING.call_once(|| {
        on_main(|| unsafe {
            let center = send(class(c"MPRemoteCommandCenter"), c"sharedCommandCenter");
            let target = target();
            for (command, action) in [
                (c"playCommand", c"play:"),
                (c"pauseCommand", c"pause:"),
                (c"togglePlayPauseCommand", c"toggle:"),
                (c"nextTrackCommand", c"next:"),
                (c"previousTrackCommand", c"previous:"),
                (c"changePlaybackPositionCommand", c"seek:"),
            ] {
                send_id_id(send(center, command), c"addTarget:action:", target, sel(action));
            }
        });
    });
}

pub(super) fn now_playing(now: Option<Now>) {
    listen();
    on_main(move || unsafe {
        let center = send(class(c"MPNowPlayingInfoCenter"), c"defaultCenter");
        let Some(now) = now else {
            send_id(center, c"setNowPlayingInfo:", std::ptr::null_mut());
            #[cfg(target_os = "macos")]
            send_usize(center, c"setPlaybackState:", 3);
            return;
        };
        let info = send(class(c"NSMutableDictionary"), c"dictionary");
        let number = |value: f64| send_f64(class(c"NSNumber"), c"numberWithDouble:", value);
        send_id_id(info, c"setObject:forKey:", string(&now.title), MPMediaItemPropertyTitle);
        send_id_id(info, c"setObject:forKey:", string(&now.artist), MPMediaItemPropertyArtist);
        send_id_id(
            info,
            c"setObject:forKey:",
            number(now.duration_ms as f64 / 1000.0),
            MPMediaItemPropertyPlaybackDuration,
        );
        send_id_id(
            info,
            c"setObject:forKey:",
            number(now.position_ms as f64 / 1000.0),
            MPNowPlayingInfoPropertyElapsedPlaybackTime,
        );
        send_id_id(
            info,
            c"setObject:forKey:",
            number(if now.playing { f64::from(now.rate) } else { 0.0 }),
            MPNowPlayingInfoPropertyPlaybackRate,
        );
        send_id(center, c"setNowPlayingInfo:", info);
        #[cfg(target_os = "macos")]
        send_usize(center, c"setPlaybackState:", if now.playing { 1 } else { 2 });
    });
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
