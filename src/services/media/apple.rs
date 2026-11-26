//! The system's media controls on Apple platforms: Now Playing shows what plays, and the
//! remote commands (the keyboard's media keys, headphones, Control Center) come back as
//! [`Command`]s.

#![allow(clippy::missing_transmute_annotations)]

use std::{
    ffi::c_void,
    sync::{
        Mutex, Once,
        atomic::{AtomicPtr, Ordering},
    },
};

use super::{Command, Now};
#[cfg(target_os = "ios")]
use crate::services::apple::objc_msgSend;
use crate::services::apple::{
    Id, Sel, class, class_addMethod, get_f64, objc_allocateClassPair, objc_registerClassPair, on_main, sel, send,
    send_f64, send_id, send_id_id, send_usize, string,
};

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
    crate::services::wake();
}

pub(super) fn take() -> Vec<Command> {
    QUEUE.lock().map(|mut queue| std::mem::take(&mut *queue)).unwrap_or_default()
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
        #[cfg(target_os = "ios")]
        class_addMethod(
            made,
            sel(c"leaving:"),
            std::mem::transmute(leaving as extern "C" fn(Id, Sel, Id)),
            c"v@:@".as_ptr(),
        );
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
            #[cfg(target_os = "ios")]
            {
                let observe: unsafe extern "C" fn(Id, Sel, Id, Sel, Id, Id) =
                    std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
                observe(
                    send(class(c"NSNotificationCenter"), c"defaultCenter"),
                    sel(c"addObserver:selector:name:object:"),
                    target,
                    sel(c"leaving:"),
                    string("UIApplicationWillResignActiveNotification"),
                    std::ptr::null_mut(),
                );
            }
        });
    });
}

#[cfg(target_os = "ios")]
extern "C" fn leaving(_: Id, _: Sel, _: Id) {
    unsafe {
        let player_layer = class(c"AVPlayerLayer");
        if player_layer.is_null() {
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
                keep_playing(send(send_usize(windows, c"objectAtIndex:", at), c"layer"), player_layer, 0);
            }
        }
    }
}

#[cfg(target_os = "ios")]
unsafe fn keep_playing(layer: Id, player_layer: Id, depth: u8) {
    unsafe {
        if layer.is_null() || depth > 64 {
            return;
        }
        let is: unsafe extern "C" fn(Id, Sel, Id) -> bool = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        if is(layer, sel(c"isKindOfClass:"), player_layer) {
            let player = send(layer, c"player");
            if !player.is_null() {
                send_usize(player, c"setAudiovisualBackgroundPlaybackPolicy:", 3);
            }
        }
        let sublayers = send(layer, c"sublayers");
        if sublayers.is_null() {
            return;
        }
        let count: unsafe extern "C" fn(Id, Sel) -> usize = std::mem::transmute(objc_msgSend as unsafe extern "C" fn());
        for index in 0..count(sublayers, sel(c"count")) {
            keep_playing(send_usize(sublayers, c"objectAtIndex:", index), player_layer, depth + 1);
        }
    }
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
