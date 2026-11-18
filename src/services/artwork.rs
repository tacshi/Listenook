use std::{
    cell::RefCell,
    collections::HashMap,
    path::{Path, PathBuf},
};

use listenook_core::Job;
use nsh_core::prelude::*;
use symphonia::core::{
    formats::FormatOptions,
    io::MediaSourceStream,
    meta::{MetadataOptions, StandardVisualKey, Visual},
    probe::Hint,
};

use crate::state::persist;

const NONE: &str = "cover.none";

#[derive(Debug, Clone, PartialEq)]
enum Cover {
    Making,
    Found(String),
    Missing,
}

thread_local! {
    static COVERS: RefCell<HashMap<String, Cover>> = RefCell::new(HashMap::new());
    static CHANGED: Signal<u64> = Owner::detached().run(|| signal(0));
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct File {
    id: String,
    source: PathBuf,
    video: bool,
    duration_ms: i64,
}

impl File {
    pub(crate) fn of(job: &Job) -> File {
        let extension = listenook_core::subtitles::extension(&job.source_path);
        File {
            id: job.id.clone(),
            source: PathBuf::from(&job.source_path),
            video: job.has_video() || crate::pages::VIDEO_EXTENSIONS.contains(&extension.as_str()),
            duration_ms: job.duration_ms(),
        }
    }

    pub(crate) fn cover(&self) -> String {
        CHANGED.with(|changed| changed.get());
        if let Some(cover) = COVERS.with(|covers| covers.borrow().get(&self.id).cloned()) {
            return match cover {
                Cover::Found(path) => path,
                Cover::Making | Cover::Missing => String::new(),
            };
        }
        let Some(folder) = persist::data_root().map(|root| root.join("jobs").join(&self.id)) else {
            return String::new();
        };
        if let Some(path) = saved(&folder) {
            remember(&self.id, Cover::Found(path.clone()));
            return path;
        }
        if folder.join(NONE).exists() || !folder.is_dir() || !self.source.is_file() {
            remember(&self.id, Cover::Missing);
            return String::new();
        }
        remember(&self.id, Cover::Making);
        let (id, source, video, at_ms) = (self.id.clone(), self.source.clone(), self.video, frame_at(self.duration_ms));
        spawn(async move {
            let made = blocking(move || make(&source, &folder, video, at_ms)).await.ok().flatten();
            remember(&id, made.map_or(Cover::Missing, Cover::Found));
            CHANGED.with(|changed| changed.update(|count| *count += 1));
        });
        String::new()
    }
}

fn remember(id: &str, cover: Cover) {
    COVERS.with(|covers| covers.borrow_mut().insert(id.to_owned(), cover));
}

fn saved(folder: &Path) -> Option<String> {
    ["cover.jpg", "cover.png"]
        .iter()
        .map(|name| folder.join(name))
        .find(|path| path.is_file())
        .map(|path| path.to_string_lossy().into_owned())
}

fn frame_at(duration_ms: i64) -> i64 {
    if duration_ms > 0 { (duration_ms / 10).min(10_000) } else { 1_000 }
}

fn make(source: &Path, folder: &Path, video: bool, at_ms: i64) -> Option<String> {
    if let Some((bytes, extension)) = embedded(source) {
        let path = folder.join(format!("cover.{extension}"));
        if std::fs::write(&path, bytes).is_ok() {
            return Some(path.to_string_lossy().into_owned());
        }
    }
    if video {
        #[cfg(target_vendor = "apple")]
        {
            let path = folder.join("cover.jpg");
            if frame::grab(source, &path, at_ms) {
                return Some(path.to_string_lossy().into_owned());
            }
        }
        if cfg!(not(target_vendor = "apple")) {
            let _ = at_ms;
            return None;
        }
    }
    let _ = std::fs::write(folder.join(NONE), b"");
    None
}

fn embedded(source: &Path) -> Option<(Vec<u8>, &'static str)> {
    let stream = MediaSourceStream::new(Box::new(std::fs::File::open(source).ok()?), Default::default());
    let mut hint = Hint::new();
    if let Some(extension) = source.extension().and_then(|e| e.to_str()) {
        hint.with_extension(extension);
    }
    let mut probed = symphonia::default::get_probe()
        .format(&hint, stream, &FormatOptions::default(), &MetadataOptions::default())
        .ok()?;
    if let Some(found) = probed.metadata.get().and_then(|metadata| metadata.current().and_then(|r| pick(r.visuals()))) {
        return Some(found);
    }
    probed.format.metadata().current().and_then(|revision| pick(revision.visuals()))
}

fn pick(visuals: &[Visual]) -> Option<(Vec<u8>, &'static str)> {
    let visual = visuals
        .iter()
        .find(|visual| visual.usage == Some(StandardVisualKey::FrontCover))
        .or_else(|| visuals.first())
        .filter(|visual| !visual.data.is_empty())?;
    let extension = if visual.media_type.contains("png") { "png" } else { "jpg" };
    Some((visual.data.to_vec(), extension))
}

#[cfg(target_vendor = "apple")]
mod frame {
    #![allow(clippy::missing_transmute_annotations)]

    use std::{
        ffi::{CString, c_char, c_void},
        path::Path,
        ptr::{null, null_mut},
    };

    type Id = *mut c_void;
    type Sel = *const c_void;

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct CMTime {
        value: i64,
        timescale: i32,
        flags: u32,
        epoch: i64,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct CGSize {
        width: f64,
        height: f64,
    }

    const LONGEST_SIDE: f64 = 640.0;

    #[link(name = "objc")]
    unsafe extern "C" {
        fn objc_getClass(name: *const c_char) -> Id;
        fn sel_registerName(name: *const c_char) -> Sel;
        fn objc_msgSend();
        fn objc_autoreleasePoolPush() -> *mut c_void;
        fn objc_autoreleasePoolPop(pool: *mut c_void);
    }

    #[link(name = "AVFoundation", kind = "framework")]
    unsafe extern "C" {}

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFRelease(object: *const c_void);
    }

    #[link(name = "CoreGraphics", kind = "framework")]
    unsafe extern "C" {
        fn CGImageRelease(image: *const c_void);
    }

    #[link(name = "ImageIO", kind = "framework")]
    unsafe extern "C" {
        fn CGImageDestinationCreateWithURL(url: Id, kind: Id, count: usize, options: *const c_void) -> *mut c_void;
        fn CGImageDestinationAddImage(destination: *mut c_void, image: *const c_void, properties: *const c_void);
        fn CGImageDestinationFinalize(destination: *mut c_void) -> bool;
    }

    fn class(name: &str) -> Id {
        let name = CString::new(name).expect("a class name has no NUL");
        unsafe { objc_getClass(name.as_ptr()) }
    }

    fn sel(name: &str) -> Sel {
        let name = CString::new(name).expect("a selector has no NUL");
        unsafe { sel_registerName(name.as_ptr()) }
    }

    unsafe fn string(text: &str) -> Id {
        let Ok(text) = CString::new(text) else {
            return null_mut();
        };
        let send: extern "C" fn(Id, Sel, *const c_char) -> Id =
            unsafe { std::mem::transmute(objc_msgSend as unsafe extern "C" fn()) };
        send(class("NSString"), sel("stringWithUTF8String:"), text.as_ptr())
    }

    unsafe fn file_url(path: &Path) -> Id {
        let path = unsafe { string(&path.to_string_lossy()) };
        if path.is_null() {
            return null_mut();
        }
        let send: extern "C" fn(Id, Sel, Id) -> Id =
            unsafe { std::mem::transmute(objc_msgSend as unsafe extern "C" fn()) };
        send(class("NSURL"), sel("fileURLWithPath:"), path)
    }

    /// Saves a frame of the video at `source`, `at_ms` in (else its first),
    /// as a JPEG at `target`, turned as the video shows.
    pub(super) fn grab(source: &Path, target: &Path, at_ms: i64) -> bool {
        unsafe {
            let pool = objc_autoreleasePoolPush();
            let saved = grab_in_pool(source, target, at_ms);
            objc_autoreleasePoolPop(pool);
            saved
        }
    }

    unsafe fn grab_in_pool(source: &Path, target: &Path, at_ms: i64) -> bool {
        let msg = objc_msgSend as unsafe extern "C" fn();
        let send1: extern "C" fn(Id, Sel, Id) -> Id = unsafe { std::mem::transmute(msg) };
        let send2: extern "C" fn(Id, Sel, Id, Id) -> Id = unsafe { std::mem::transmute(msg) };
        let set_bool: extern "C" fn(Id, Sel, bool) = unsafe { std::mem::transmute(msg) };
        let set_size: extern "C" fn(Id, Sel, CGSize) = unsafe { std::mem::transmute(msg) };
        let copy_image: extern "C" fn(Id, Sel, CMTime, *mut CMTime, *mut Id) -> *const c_void =
            unsafe { std::mem::transmute(msg) };

        let url = unsafe { file_url(source) };
        if url.is_null() {
            return false;
        }
        let asset = send2(class("AVURLAsset"), sel("URLAssetWithURL:options:"), url, null_mut());
        if asset.is_null() {
            return false;
        }
        let generator = send1(class("AVAssetImageGenerator"), sel("assetImageGeneratorWithAsset:"), asset);
        if generator.is_null() {
            return false;
        }
        set_bool(generator, sel("setAppliesPreferredTrackTransform:"), true);
        set_size(generator, sel("setMaximumSize:"), CGSize { width: LONGEST_SIDE, height: LONGEST_SIDE });
        let copy = sel("copyCGImageAtTime:actualTime:error:");
        let at = |ms: i64| CMTime { value: ms, timescale: 1000, flags: 1, epoch: 0 };
        let mut error: Id = null_mut();
        let mut image = copy_image(generator, copy, at(at_ms), null_mut(), &mut error);
        if image.is_null() && at_ms > 0 {
            image = copy_image(generator, copy, at(0), null_mut(), &mut error);
        }
        if image.is_null() {
            return false;
        }
        unsafe {
            let destination = CGImageDestinationCreateWithURL(file_url(target), string("public.jpeg"), 1, null());
            let saved = !destination.is_null() && {
                CGImageDestinationAddImage(destination, image, null());
                let done = CGImageDestinationFinalize(destination);
                CFRelease(destination);
                done
            };
            CGImageRelease(image);
            saved
        }
    }
}
