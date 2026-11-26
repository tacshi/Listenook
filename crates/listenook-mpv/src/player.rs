//! A player on every platform: the props the app sets become mpv's properties, and what mpv
//! reports becomes the events the app listens to (`load`, `progress`, `end`, `error`,
//! `buffer`), as nsh's own video element sends them. Only how the picture is shown differs by
//! platform ([`Screen`]).

use std::{
    sync::{
        Arc, Weak,
        atomic::{AtomicBool, AtomicU32, Ordering},
    },
    time::{Duration, Instant},
};

use serde_json::{Value as JsonValue, json};

use crate::mpv::{Change, Ended, Event, Mpv};

/// Sends an event to the app; callable from any thread.
pub(crate) type Emit = Arc<dyn Fn(&str, JsonValue) + Send + Sync>;

/// Where mpv shows the picture: its options (`vo`, `gpu-context`…), the native view it draws
/// into, and what must outlive mpv (the view's layer), dropped once mpv has stopped.
pub(crate) struct Screen {
    pub(crate) options: Vec<(&'static str, String)>,
    pub(crate) wid: Option<i64>,
    pub(crate) keep: Box<dyn Send>,
    /// Called (on mpv's event thread) once each file's tracks are known and before anything of
    /// it is decoded, while mpv waits: to size what mpv draws into.
    pub(crate) before_playing: Option<BeforePlaying>,
}

/// Told the size (width, height) of the video about to play.
pub(crate) type BeforePlaying = Box<dyn Fn((f64, f64)) + Send + Sync>;

/// What every player is started with, whatever the platform.
const OPTIONS: [(&str, &str); 13] = [
    ("config", "no"),
    ("terminal", "no"),
    ("idle", "yes"),
    // At its end a file stays open and paused, so it can be played again or sought in.
    ("keep-open", "yes"),
    ("pause", "yes"),
    ("hr-seek", "yes"),
    ("audio-pitch-correction", "yes"),
    ("hwdec", "auto-safe"),
    // The app draws its own subtitles.
    ("sid", "no"),
    ("sub-auto", "no"),
    ("audio-display", "no"),
    ("input-default-bindings", "no"),
    ("input-vo-keyboard", "no"),
];

/// What the app's props and mpv's thread share.
#[derive(Default)]
struct Shared {
    repeat: AtomicBool,
    /// Milliseconds between `progress` events.
    every_ms: AtomicU32,
    /// Stopped at the end of the file.
    ended: AtomicBool,
    quit: AtomicBool,
}

/// The props as last applied: `paused` only acts when it changes, since mpv pauses by itself at
/// a file's end.
#[derive(Default)]
struct Applied {
    source: Option<String>,
    paused: Option<bool>,
}

pub(crate) struct Player {
    mpv: Option<Arc<Mpv>>,
    shared: Arc<Shared>,
    applied: Applied,
    emit: Emit,
}

impl Player {
    pub(crate) fn new(screen: Screen, emit: Emit) -> Self {
        let shared = Arc::new(Shared { every_ms: AtomicU32::new(250), ..Shared::default() });
        let mut options: Vec<(&str, &str)> = OPTIONS.to_vec();
        options.extend(screen.options.iter().map(|(name, value)| (*name, value.as_str())));
        let mpv = match Mpv::start(&options, screen.wid, screen.keep) {
            Ok(mpv) => Arc::new(mpv),
            Err(why) => {
                log::error!("mpv could not start: {why}");
                emit("error", json!({ "message": why }));
                return Player { mpv: None, shared, applied: Applied::default(), emit };
            }
        };
        let before_playing = screen.before_playing;
        if before_playing.is_some() {
            mpv.pause_before_playing();
        }
        let (thread_mpv, thread_shared, thread_emit) = (mpv.clone(), shared.clone(), emit.clone());
        let spawned = std::thread::Builder::new()
            .name("mpv-events".into())
            .spawn(move || listen(&thread_mpv, &thread_shared, &*thread_emit, before_playing.as_deref()));
        if let Err(why) = spawned {
            log::error!("mpv's event thread could not start: {why}");
        }
        Player { mpv: Some(mpv), shared, applied: Applied::default(), emit }
    }

    /// What the view does with mpv's picture, from any thread.
    pub(crate) fn output(&self) -> Output {
        Output(self.mpv.as_ref().map_or_else(Weak::new, Arc::downgrade))
    }

    /// The app set prop `name` to `value` (`None`: removed): `source`, or `playback` (an object of
    /// `paused`, `rate`, `volume`, `muted`, `repeat` and `progressInterval`).
    pub(crate) fn set_prop(&mut self, name: &str, value: Option<&JsonValue>) {
        if name == "playback" {
            for (field, value) in value.and_then(JsonValue::as_object).into_iter().flatten() {
                self.apply(field, Some(value));
            }
            return;
        }
        self.apply(name, value);
    }

    fn apply(&mut self, name: &str, value: Option<&JsonValue>) {
        let Some(mpv) = self.mpv.clone() else { return };
        match name {
            "source" => {
                let source = value.and_then(JsonValue::as_str).filter(|s| !s.is_empty()).map(str::to_owned);
                if source == self.applied.source {
                    return;
                }
                self.shared.ended.store(false, Ordering::Relaxed);
                match &source {
                    Some(source) => {
                        log::debug!("mpv loads {source}");
                        (self.emit)("loadStart", JsonValue::Null);
                        mpv.command(&["loadfile", &location(source), "replace"]);
                    }
                    None => mpv.command(&["stop"]),
                }
                self.applied.source = source;
            }
            "paused" => {
                let paused = value.and_then(JsonValue::as_bool).unwrap_or(false);
                if self.applied.paused == Some(paused) {
                    return;
                }
                self.applied.paused = Some(paused);
                if !paused && self.shared.ended.swap(false, Ordering::Relaxed) {
                    mpv.command(&["seek", "0", "absolute+exact"]);
                }
                mpv.set_flag("pause", paused);
            }
            "rate" => {
                let rate = value.and_then(JsonValue::as_f64).unwrap_or(1.0);
                if rate > 0.0 {
                    mpv.set_number("speed", rate);
                }
            }
            "volume" => {
                mpv.set_number("volume", value.and_then(JsonValue::as_f64).unwrap_or(1.0).clamp(0.0, 1.0) * 100.0)
            }
            "muted" => mpv.set_flag("mute", value.and_then(JsonValue::as_bool).unwrap_or(false)),
            "repeat" => {
                self.shared.repeat.store(value.and_then(JsonValue::as_bool).unwrap_or(false), Ordering::Relaxed)
            }
            "progressInterval" => {
                let every = value.and_then(JsonValue::as_f64).unwrap_or(250.0).max(16.0);
                self.shared.every_ms.store(every as u32, Ordering::Relaxed);
                mpv.wake();
            }
            _ => {}
        }
    }

    /// The app called `ref.command(name, args)`: `seek` to `args` seconds.
    pub(crate) fn command(&mut self, name: &str, args: &JsonValue) {
        let (Some(mpv), "seek") = (&self.mpv, name) else { return };
        let Some(seconds) = args.as_f64().or_else(|| args.get("seconds").and_then(JsonValue::as_f64)) else { return };
        mpv.command(&["seek", &format!("{:.3}", seconds.max(0.0)), "absolute+exact"]);
        // Sought back from the end while meant to play, it plays on, as a player does.
        if self.shared.ended.swap(false, Ordering::Relaxed) && self.applied.paused == Some(false) {
            mpv.set_flag("pause", false);
        }
    }
}

impl Drop for Player {
    /// Ends the event thread. mpv stops where its last reference goes, never on the main thread:
    /// stopping waits for its video output, which may need the main thread to finish.
    fn drop(&mut self) {
        self.shared.quit.store(true, Ordering::Relaxed);
        if let Some(mpv) = self.mpv.take() {
            mpv.wake();
            let _ = std::thread::Builder::new().name("mpv-stop".into()).spawn(move || drop(mpv));
        }
    }
}

/// What a platform's view does with mpv's picture (from any thread), while the player lives.
#[derive(Clone)]
pub(crate) struct Output(Weak<Mpv>);

impl Output {
    fn mpv(&self) -> Option<Arc<Mpv>> {
        self.0.upgrade()
    }

    /// Has mpv draw through `api` from now on (`vo=libmpv`); `on_frame` is called (on mpv's
    /// threads) whenever there is something new to draw.
    #[cfg(any(target_os = "macos", target_os = "linux", windows))]
    pub(crate) fn render(
        &self,
        api: crate::render::Api,
        on_frame: crate::render::OnFrame,
    ) -> Result<crate::render::Render, String> {
        let mpv = self.mpv().ok_or("mpv did not start")?;
        let render = crate::render::Render::new(&mpv, api, on_frame)?;
        // A file loaded before there was anything to draw into plays without its picture until
        // the video output starts again.
        mpv.set_text("vo", "libmpv");
        Ok(render)
    }

    /// Shows the picture, or turns it off (the sound plays on).
    #[cfg(target_os = "ios")]
    pub(crate) fn show_picture(&self, on: bool) {
        if let Some(mpv) = self.mpv() {
            mpv.command(&["set", "vid", if on { "auto" } else { "no" }]);
        }
    }

    /// Draws into the native surface `wid`, `width` × `height` pixels, from now on.
    #[cfg(target_os = "android")]
    pub(crate) fn attach(&self, wid: i64, size: (i32, i32)) {
        if let Some(mpv) = self.mpv() {
            self.resize(size);
            mpv.set_wid(wid);
            mpv.set_text("force-window", "yes");
            mpv.set_text("vo", "gpu");
        }
    }

    /// The surface is `width` × `height` pixels now.
    #[cfg(target_os = "android")]
    pub(crate) fn resize(&self, (width, height): (i32, i32)) {
        if let Some(mpv) = self.mpv() {
            mpv.set_text("android-surface-size", &format!("{width}x{height}"));
        }
    }

    /// Stops drawing into the surface, which is about to go.
    #[cfg(target_os = "android")]
    pub(crate) fn detach(&self) {
        if let Some(mpv) = self.mpv() {
            mpv.set_text("vo", "null");
            mpv.set_text("force-window", "no");
            mpv.set_wid(0);
        }
    }
}

/// The size (width, height, as shown) of the video track mpv is about to play: its first, as
/// mpv has not chosen yet when it is asked (`on_preloaded`) and chooses that one.
fn video_size(mpv: &Mpv) -> Option<(f64, f64)> {
    let count = mpv.integer("track-list/count").unwrap_or(0);
    let track = (0..count).map(|at| format!("track-list/{at}/")).find(|track| {
        mpv.text(&format!("{track}type")).as_deref() == Some("video")
            && mpv.text(&format!("{track}albumart")).as_deref() != Some("yes")
    })?;
    let field = |name: &str| format!("{track}{name}");
    let (width, height) = (mpv.integer(&field("demux-w"))?, mpv.integer(&field("demux-h"))?);
    let aspect = mpv.number(&field("demux-par")).filter(|par| *par > 0.0).unwrap_or(1.0);
    let (width, height) = (width as f64 * aspect, height as f64);
    let turned = mpv.integer(&field("demux-rotation")).is_some_and(|degrees| degrees % 180 == 90);
    let size = if turned { (height, width) } else { (width, height) };
    (size.0 > 0.0 && size.1 > 0.0).then_some(size)
}

/// What mpv loads for a source: a path for a `file://` URL, the source itself otherwise.
fn location(source: &str) -> String {
    match source.strip_prefix("file://") {
        Some(path) => percent_decoded(path),
        None => source.to_owned(),
    }
}

fn percent_decoded(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while at < bytes.len() {
        let hex = |b: u8| (b as char).to_digit(16);
        if bytes[at] == b'%'
            && let (Some(high), Some(low)) =
                (bytes.get(at + 1).copied().and_then(hex), bytes.get(at + 2).copied().and_then(hex))
        {
            out.push((high * 16 + low) as u8);
            at += 3;
        } else {
            out.push(bytes[at]);
            at += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Reads mpv's events until the player goes, sending the app's events.
fn listen(
    mpv: &Mpv,
    shared: &Shared,
    emit: &(dyn Fn(&str, JsonValue) + Send + Sync),
    before_playing: Option<&(dyn Fn((f64, f64)) + Send + Sync)>,
) {
    let mut track = Track::default();
    let mut next_tick = Instant::now();
    while !shared.quit.load(Ordering::Relaxed) {
        let every = Duration::from_millis(u64::from(shared.every_ms.load(Ordering::Relaxed)));
        let wait = next_tick.saturating_duration_since(Instant::now()).min(every);
        let mut event = mpv.wait_event(wait.as_secs_f64());
        loop {
            match event {
                Event::Nothing => break,
                Event::Shutdown => return,
                Event::BeforePlaying(id) => {
                    if let (Some(before), Some(size)) = (before_playing, video_size(mpv)) {
                        before(size);
                    }
                    mpv.resume(id);
                }
                event => {
                    let signals = match event {
                        Event::Loaded => {
                            let size = |name| mpv.integer(name).unwrap_or(0);
                            vec![track.loaded(mpv.number("duration"), (size("width"), size("height")))]
                        }
                        event => track.on(&event),
                    };
                    for signal in signals {
                        match signal {
                            Signal::Load { duration, width, height } => emit(
                                "load",
                                json!({ "duration": duration.unwrap_or(f64::NAN), "width": width, "height": height }),
                            ),
                            Signal::End => {
                                shared.ended.store(true, Ordering::Relaxed);
                                emit("end", JsonValue::Null);
                                if shared.repeat.load(Ordering::Relaxed) {
                                    shared.ended.store(false, Ordering::Relaxed);
                                    mpv.command(&["seek", "0", "absolute+exact"]);
                                    mpv.set_flag("pause", false);
                                }
                            }
                            Signal::Error(message) => emit("error", json!({ "message": message })),
                            Signal::Buffer(waiting) => emit("buffer", json!({ "isBuffering": waiting })),
                        }
                    }
                }
            }
            event = mpv.wait_event(0.0);
        }
        if Instant::now() >= next_tick {
            next_tick = Instant::now() + every;
            if let Some((at, duration)) = track.progress() {
                emit("progress", json!({ "currentTime": at, "duration": duration }));
            }
        }
    }
}

/// What the app hears about, apart from `progress`.
#[derive(Debug, Clone, PartialEq)]
enum Signal {
    /// A file is loaded: how long it lasts (seconds) and its picture's size (pixels).
    Load {
        duration: Option<f64>,
        width: i64,
        height: i64,
    },
    End,
    Error(String),
    Buffer(bool),
}

/// The file being played, as mpv's events describe it.
#[derive(Debug, Default)]
struct Track {
    loaded: bool,
    duration: Option<f64>,
    position: Option<f64>,
    /// The position last reported in a `progress` event.
    reported: Option<f64>,
    at_end: bool,
    waiting: bool,
}

impl Track {
    fn loaded(&mut self, duration: Option<f64>, (width, height): (i64, i64)) -> Signal {
        self.loaded = true;
        self.duration = duration.or(self.duration);
        Signal::Load { duration: self.duration, width, height }
    }

    fn on(&mut self, event: &Event) -> Vec<Signal> {
        match event {
            Event::Starting => {
                *self = Track::default();
                vec![]
            }
            Event::Ended(Ended::Failed(why)) => {
                self.loaded = false;
                vec![Signal::Error(why.clone())]
            }
            Event::Ended(Ended::Done) if self.loaded => {
                self.loaded = false;
                vec![Signal::End]
            }
            Event::Changed(Change::Position(at)) => {
                self.position = *at;
                vec![]
            }
            Event::Changed(Change::Duration(duration)) => {
                self.duration = duration.or(self.duration);
                vec![]
            }
            Event::Changed(Change::AtEnd(at_end)) => {
                let reached = *at_end && !self.at_end && self.loaded;
                self.at_end = *at_end;
                if reached { vec![Signal::End] } else { vec![] }
            }
            Event::Changed(Change::Waiting(waiting)) if *waiting != self.waiting => {
                self.waiting = *waiting;
                vec![Signal::Buffer(*waiting)]
            }
            _ => vec![],
        }
    }

    /// Where the file is and how long it lasts, when it moved since the last report.
    fn progress(&mut self) -> Option<(f64, f64)> {
        let at = self.position.filter(|_| self.loaded)?;
        if self.reported == Some(at) {
            return None;
        }
        self.reported = Some(at);
        Some((at, self.duration.unwrap_or(f64::NAN)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn loaded() -> Track {
        let mut track = Track::default();
        track.on(&Event::Starting);
        track.loaded(Some(10.0), (1920, 1080));
        track
    }

    #[test]
    fn progress_is_reported_when_the_position_moves() {
        let mut track = loaded();
        assert_eq!(track.progress(), None);
        track.on(&Event::Changed(Change::Position(Some(1.5))));
        assert_eq!(track.progress(), Some((1.5, 10.0)));
        assert_eq!(track.progress(), None);
        track.on(&Event::Changed(Change::Position(Some(0.5))));
        assert_eq!(track.progress(), Some((0.5, 10.0)));
    }

    #[test]
    fn nothing_is_reported_before_a_file_loads() {
        let mut track = Track::default();
        track.on(&Event::Changed(Change::Position(Some(1.0))));
        assert_eq!(track.progress(), None);
    }

    #[test]
    fn reaching_the_end_is_heard_once() {
        let mut track = loaded();
        assert_eq!(track.on(&Event::Changed(Change::AtEnd(true))), vec![Signal::End]);
        assert_eq!(track.on(&Event::Changed(Change::AtEnd(true))), vec![]);
        track.on(&Event::Changed(Change::AtEnd(false)));
        assert_eq!(track.on(&Event::Changed(Change::AtEnd(true))), vec![Signal::End]);
    }

    #[test]
    fn a_file_that_fails_is_an_error_and_a_new_one_starts_over() {
        let mut track = loaded();
        assert_eq!(
            track.on(&Event::Ended(Ended::Failed("unrecognized file format".into()))),
            vec![Signal::Error("unrecognized file format".into())]
        );
        assert_eq!(track.on(&Event::Ended(Ended::Done)), vec![]);
        track.on(&Event::Starting);
        assert_eq!(track.duration, None);
    }

    #[test]
    fn a_stopped_file_is_not_an_end() {
        let mut track = loaded();
        assert_eq!(track.on(&Event::Ended(Ended::Stopped)), vec![]);
    }

    #[test]
    fn waiting_for_data_is_reported_as_it_changes() {
        let mut track = loaded();
        assert_eq!(track.on(&Event::Changed(Change::Waiting(true))), vec![Signal::Buffer(true)]);
        assert_eq!(track.on(&Event::Changed(Change::Waiting(true))), vec![]);
        assert_eq!(track.on(&Event::Changed(Change::Waiting(false))), vec![Signal::Buffer(false)]);
    }

    #[test]
    fn file_urls_become_paths() {
        assert_eq!(location("file:///Users/me/My%20Videos/a%E2%80%9Cb.mkv"), "/Users/me/My Videos/a\u{201c}b.mkv");
        assert_eq!(location("https://example.com/a%20b.mp3"), "https://example.com/a%20b.mp3");
    }
}
