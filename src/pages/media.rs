//! The player recordings and videos play in: libmpv, as the `listenook.mpv` native component
//! (crates/listenook-mpv), so any format FFmpeg reads plays on every platform.

use nsh_core::prelude::*;
use serde_json::{Value as JsonValue, json};

/// A handle on a [`media_view`], to seek it.
#[derive(Clone, Copy)]
pub(crate) struct MediaRef(ElementRef);

pub(crate) fn media_ref() -> MediaRef {
    MediaRef(element_ref())
}

impl MediaRef {
    /// Plays from `seconds`, exactly there.
    pub(crate) fn seek(&self, seconds: f64) {
        self.0.command("seek", json!(seconds));
    }
}

/// How a [`media_view`] plays, as the page wants it now.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct Playback {
    pub(crate) paused: bool,
    /// How fast, keeping voices at their pitch.
    pub(crate) rate: f32,
    /// 0 to 1.
    pub(crate) volume: f32,
    pub(crate) muted: bool,
    /// Starts over at its end.
    pub(crate) repeat: bool,
    /// Milliseconds between [`MediaEvent::Progress`] events while it plays.
    pub(crate) progress_ms: f32,
}

/// What a [`media_view`] tells its page.
pub(crate) enum MediaEvent {
    /// The file is loaded: how long it lasts and its picture's size.
    Loaded(VideoInfo),
    /// It played on.
    Progress(VideoProgress),
    /// It reached its end.
    Ended,
    /// It cannot be played.
    Failed,
}

impl MediaEvent {
    fn of(event: &NativeEvent) -> Option<MediaEvent> {
        let number = |name: &str| event.data.get(name).and_then(JsonValue::as_f64).unwrap_or(f64::NAN) as f32;
        let pixels = |name: &str| DevicePixels(event.data.get(name).and_then(JsonValue::as_i64).unwrap_or(0) as i32);
        Some(match &*event.name {
            "load" => MediaEvent::Loaded(VideoInfo {
                duration: number("duration"),
                size: size(pixels("width"), pixels("height")),
            }),
            "progress" => MediaEvent::Progress(VideoProgress {
                current_time: number("currentTime"),
                duration: number("duration"),
            }),
            "end" => MediaEvent::Ended,
            "error" => MediaEvent::Failed,
            _ => return None,
        })
    }
}

/// A player of `source` (a `file://` URL), filling its parent, that plays as `playback` says
/// and tells `on` what happens, showing the picture of a video; `handle` seeks it.
pub(crate) struct MediaView {
    view: NativeView,
}

pub(crate) fn media_view(
    handle: &MediaRef,
    source: impl Fn() -> String + 'static,
    playback: impl Fn() -> Playback + 'static,
    on: impl Fn(MediaEvent) + 'static,
) -> MediaView {
    let view = native(listenook_mpv::NAME)
        .element_ref(&handle.0)
        .flex_1()
        .prop("source", move || JsonValue::from(source()))
        .prop("playback", move || {
            let Playback { paused, rate, volume, muted, repeat, progress_ms } = playback();
            json!({
                "paused": paused,
                "rate": rate,
                "volume": volume,
                "muted": muted,
                "repeat": repeat,
                "progressInterval": progress_ms,
            })
        })
        .on_native_event(move |event: &NativeEvent| {
            if let Some(event) = MediaEvent::of(event) {
                on(event);
            }
        });
    MediaView { view }
}

impl MediaView {
    /// Keeps the window it is in at the shape of `shape` (width, height) as the window is
    /// resized, where the platform can (macOS); `None` lets the window take any shape.
    pub(crate) fn window_shape(self, shape: impl Fn() -> Option<(f32, f32)> + 'static) -> Self {
        let shape = move || shape().map_or(JsonValue::Null, |(width, height)| json!([width, height]));
        MediaView { view: self.view.prop("windowShape", shape) }
    }

    /// Keeps the window it is in out of sight while it opens, until the video's picture shows at
    /// its shape ([`Self::window_shape`]), or a moment passes (Windows, where the window would
    /// otherwise show empty while mpv compiles its shaders, then change shape).
    pub(crate) fn hold_window(self, hold: bool) -> Self {
        MediaView { view: self.view.prop("holdWindow", move || JsonValue::from(hold)) }
    }
}

impl IntoElement for MediaView {
    fn into_element(self) -> AnyElement {
        self.view.into_element()
    }
}
