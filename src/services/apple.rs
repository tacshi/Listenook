//! What the app asks of macOS and iOS that NSH has no call for: the
//! system's media controls (Now Playing, the media keys, the lock screen).
//! Plain Objective-C messages:
//! the frameworks are the system's own, and nothing is added to the build.
//!
//! The system calls back on its own threads; what it asks is put in a
//! queue that `services::media` empties on the engine thread.

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

/// Shows the app in the Dock, or keeps it out of it: an app out of the
/// Dock is reached from its menu-bar icon.
#[cfg(target_os = "macos")]
pub(super) fn set_dock_icon(visible: bool) {
    on_main(move || {
        // SAFETY: AppKit's shared application, on the main thread.
        unsafe {
            let app = send(class(c"NSApplication"), c"sharedApplication");
            // NSApplicationActivationPolicyRegular, or …Accessory.
            let policy = if visible { 0 } else { 1 };
            let current: unsafe extern "C" fn(Id, Sel) -> usize =
                std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
            if current(app, sel(c"activationPolicy")) == policy {
                return;
            }
            send_usize(app, c"setActivationPolicy:", policy);
            // Changing it puts the app behind the others: back in front.
            send_usize(app, c"activateIgnoringOtherApps:", 1);
        }
    });
}

/// What the system asked for since the last call.
pub(super) fn take() -> Vec<Command> {
    QUEUE.lock().map(|mut queue| std::mem::take(&mut *queue)).unwrap_or_default()
}

/// Runs `work` on the main thread, where AppKit and UIKit must be called.
fn on_main(work: impl FnOnce() + Send + 'static) {
    extern "C" fn run(context: *mut c_void) {
        // SAFETY: `context` is the box made below, handed over once.
        let work = unsafe { Box::from_raw(context.cast::<Box<dyn FnOnce() + Send>>()) };
        work();
    }
    let boxed: Box<Box<dyn FnOnce() + Send>> = Box::new(Box::new(work));
    // SAFETY: the main queue outlives the app, and `run` takes the box back.
    unsafe { dispatch_async_f(&raw const _dispatch_main_q, Box::into_raw(boxed).cast(), run) };
}

// Messages, by the types of their arguments and what they return. Each is
// `objc_msgSend` seen as the function the method is.
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

// What the system calls. Each is a method of one small class made at run
// time, taking the sender or the event and answering "handled" (0).
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
    // SAFETY: the event of a change-position command has `positionTime`.
    let seconds = unsafe { get_f64(event, c"positionTime") };
    push(Command::Seek((seconds * 1000.0) as i64));
    0
}

static TARGET: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

/// The object the system's controls call.
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

/// Tells the system's controls to call here. Once is enough.
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

/// Says what is playing, or that nothing is.
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
        // A Mac is told outright whether it is playing (1) or paused (2).
        #[cfg(target_os = "macos")]
        send_usize(center, c"setPlaybackState:", if now.playing { 1 } else { 2 });
    });
}

// --- Picking files on an iPhone or iPad -----------------------------------------

#[cfg(target_os = "ios")]
#[link(name = "UniformTypeIdentifiers", kind = "framework")]
unsafe extern "C" {}

/// The files the user picked, as paths, until the engine takes them.
#[cfg(target_os = "ios")]
static PICKED: Mutex<Vec<String>> = Mutex::new(Vec::new());

/// The files picked since the last call.
#[cfg(target_os = "ios")]
pub(super) fn take_picked() -> Vec<String> {
    PICKED.lock().map(|mut picked| std::mem::take(&mut *picked)).unwrap_or_default()
}

/// The document picker's answer: the copies the system made of the files
/// the user picked, which are the app's to move where it keeps its media.
#[cfg(target_os = "ios")]
extern "C" fn documents_picked(_: Id, _: Sel, _picker: Id, urls: Id) {
    // SAFETY: `urls` is the NSArray of NSURLs UIKit hands the delegate.
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

/// Copies a file another app handed over. One opened where it lies (from
/// the Files app) is outside the app's own storage: the system lets it be
/// read only between these two calls.
#[cfg(target_os = "ios")]
pub(super) fn copy_opened(from: &str, to: &std::path::Path) -> bool {
    // SAFETY: NSURL's documented class and instance methods, on a URL
    // made here and kept alive by the autorelease pool of the caller.
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

/// Shows the system's document picker (the Files app's browser) for any
/// number of files. The system copies what is picked, however large,
/// without the app reading it into memory; [`take_picked`] gives the copies.
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

        // The window to show it over: the key one, else the first there is.
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
        // Any file: which are media is told from their names afterwards,
        // since subtitle files have no type of their own to ask for.
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
        // The presenter keeps it from here.
        send(picker, c"release");
    });
}

// --- Hardware keys on an iPad ---------------------------------------------------

#[cfg(target_os = "ios")]
unsafe extern "C" {
    fn class_getName(class: Id) -> *const c_char;
    fn object_getClass(object: Id) -> Id;
}

/// Set by whatever holds the keyboard focus, when asked (see below).
#[cfg(target_os = "ios")]
static HAS_FOCUS: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// What every responder answers `listenookHoldsFocus:` with. UIKit sends
/// an action with no target to the first responder and up from it: when
/// this runs, there is one.
#[cfg(target_os = "ios")]
extern "C" fn holds_focus(_: Id, _: Sel, _: Id) {
    HAS_FOCUS.store(true, Ordering::Release);
}

#[cfg(target_os = "ios")]
extern "C" fn can_take_keys(_: Id, _: Sel) -> bool {
    true
}

/// The app's root view (NSH's) under `view`, by its class's name.
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

/// Has every page's view laid out again, which is when NSH measures where
/// the page starts under the system's header. It measures a page coming
/// back from under one that hides the header while the header is still on
/// its way in, and hears no more of it: the page then sits a little under
/// the header until something else lays it out.
#[cfg(target_os = "ios")]
pub(super) fn remeasure_pages() {
    unsafe fn visit(view: Id, depth: u8) {
        unsafe {
            let count: unsafe extern "C" fn(Id, Sel) -> usize =
                std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
            let is_kind: unsafe extern "C" fn(Id, Sel, Id) -> bool =
                std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
            // A view whose next responder is a view controller is that
            // controller's own view: a page's among them.
            let owner = send(view, c"nextResponder");
            if !owner.is_null() && is_kind(owner, sel(c"isKindOfClass:"), class(c"UIViewController")) {
                send(view, c"setNeedsLayout");
            }
            if depth >= 16 {
                return;
            }
            let children = send(view, c"subviews");
            for at in 0..count(children, sel(c"count")) {
                visit(send_usize(children, c"objectAtIndex:", at), depth + 1);
            }
        }
    }
    on_main(|| unsafe {
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
                visit(send_usize(windows, c"objectAtIndex:", at), 0);
            }
        }
    });
}

/// Sees to it that a hardware keyboard's keys reach the app's shortcuts.
/// UIKit hands a key to whatever holds the keyboard focus and up from
/// there; with nothing holding it (no text field being typed in), the key
/// goes to the window and never passes NSH's root view, where shortcuts
/// are matched. So while nothing holds the focus, the root view is given
/// it. A text field still takes it when it is tapped, and gives it up
/// when it is done. Call now and then.
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
                // The root view may hold the focus: said once, for its class.
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
