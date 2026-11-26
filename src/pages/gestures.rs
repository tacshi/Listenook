//! A video's gestures on a touch screen: a tap does the page's own thing
//! (shows or hides the controls), a double tap on either half skips back or
//! ahead (taps right after keep skipping), a held finger plays at 3× until it
//! lifts, a sideways swipe scrubs, and a swipe up or down sets the brightness
//! (left half) or the volume (right half).

use std::{
    cell::{Cell, RefCell},
    rc::Rc,
    time::Duration,
};

use listenook_core::format;
use nsh_base::theme;
use nsh_core::prelude::*;

use crate::{
    services,
    state::store,
    ui::{self, Icon, tokens},
};

/// The rate a held finger plays at.
pub(crate) const BOOST: f32 = 3.0;
const SKIP_MS: i64 = 10_000;
/// How long a finger stays down, unmoved, to play at [`BOOST`].
const HOLD: Duration = Duration::from_millis(450);
/// How soon a second tap makes a double tap (and how long a single one waits
/// to be sure it is not).
const DOUBLE_MS: u64 = 280;
/// How long after a skip a tap skips again.
const STREAK_MS: f64 = 800.0;
/// How far a finger moves before it swipes rather than taps or holds.
const SLOP: f32 = 12.0;
/// How long a swipe's or a skip's readout stays after the finger lifts.
const LINGER: Duration = Duration::from_millis(600);
/// A full-width swipe scrubs this far (or the whole video, if shorter).
const SCRUB_SPAN_MS: i64 = 120_000;
/// How often a scrub seeks while the finger moves, in milliseconds.
const SCRUB_EVERY_MS: f64 = 150.0;

/// What the gestures act on.
pub(crate) struct Video {
    pub(crate) position: Rc<dyn Fn() -> i64>,
    pub(crate) duration: Rc<dyn Fn() -> i64>,
    pub(crate) seek: Rc<dyn Fn(i64)>,
    /// A single tap.
    pub(crate) tap: Rc<dyn Fn()>,
    /// True while a finger is held: the player's rate is [`BOOST`] then.
    pub(crate) boost: Signal<bool>,
    /// The player's own volume, which a swipe sets where the system volume
    /// cannot be (the player binds it).
    pub(crate) volume: Signal<f32>,
}

/// What the gesture shows over the picture.
#[derive(Debug, Clone, Copy, PartialEq)]
enum Shown {
    Boost,
    Scrub { to: i64, by: i64, of: i64 },
    Level { brightness: bool, value: f32 },
    Skip { forward: bool, ms: i64 },
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Mode {
    Idle,
    /// Down, not moved yet: a tap, a hold or a swipe to come.
    Pending,
    Hold,
    Scrub {
        from: i64,
        to: i64,
        sought: f64,
    },
    Level {
        brightness: bool,
        from: f32,
    },
}

#[derive(Default)]
struct Timers {
    hold: RefCell<Option<Spawned<()>>>,
    single: RefCell<Option<Spawned<()>>>,
    linger: RefCell<Option<Spawned<()>>>,
}

impl Timers {
    fn cancel(slot: &RefCell<Option<Spawned<()>>>) {
        if let Some(timer) = slot.borrow_mut().take() {
            timer.cancel();
        }
    }

    fn set(slot: &RefCell<Option<Spawned<()>>>, timer: Spawned<()>) {
        if let Some(earlier) = slot.borrow_mut().replace(timer) {
            earlier.cancel();
        }
    }
}

struct State {
    video: Video,
    shown: Signal<Option<Shown>>,
    /// How dark the picture is drawn where the screen's brightness cannot be
    /// set (0 is as filmed).
    dim: Signal<f32>,
    mode: Cell<Mode>,
    size: Cell<(f32, f32)>,
    /// Where the finger went down in the layer.
    start_x: Cell<f32>,
    /// Whether the system's brightness and volume are the ones a swipe sets.
    system: Cell<bool>,
    /// When the last single tap lifted, while it may become a double tap.
    last_tap: Cell<Option<f64>>,
    /// Skipping: until when a tap skips again, which way, and how far so far.
    streak: Cell<Option<(f64, bool, i64)>>,
    timers: Timers,
}

impl State {
    fn ahead(&self, x: f32) -> bool {
        x > self.size.get().0 / 2.0
    }

    fn linger(self: &Rc<Self>) {
        let shown = self.shown;
        Timers::set(&self.timers.linger, set_timeout(LINGER, move || shown.set(None)));
    }

    fn level(&self, brightness: bool) -> f32 {
        if self.system.get() {
            let (screen, volume) = services::levels().unwrap_or((0.5, 0.5));
            if brightness { screen } else { volume }
        } else if brightness {
            1.0 - self.dim.get_untracked() / 0.8
        } else {
            self.video.volume.get_untracked()
        }
    }

    fn set_level(&self, brightness: bool, value: f32) {
        match (self.system.get(), brightness) {
            (true, true) => services::set_brightness(value),
            (true, false) => services::set_volume(value),
            (false, true) => self.dim.set((1.0 - value) * 0.8),
            (false, false) => self.video.volume.set(value),
        }
    }

    fn skip(self: &Rc<Self>, now: f64, forward: bool) {
        let total = match self.streak.get() {
            Some((_, way, ms)) if way == forward => ms + SKIP_MS,
            _ => SKIP_MS,
        };
        self.streak.set(Some((now + STREAK_MS, forward, total)));
        let by = if forward { SKIP_MS } else { -SKIP_MS };
        let to = ((self.video.position)() + by).clamp(0, (self.video.duration)().max(0));
        (self.video.seek)(to);
        Timers::cancel(&self.timers.linger);
        self.shown.set(Some(Shown::Skip { forward, ms: total }));
        self.linger();
    }

    fn tapped(self: &Rc<Self>, now: f64) {
        let forward = self.ahead(self.start_x.get());
        if self.streak.get().is_some_and(|(until, ..)| now <= until) {
            self.skip(now, forward);
        } else if self.last_tap.take().is_some_and(|before| now - before <= DOUBLE_MS as f64) {
            Timers::cancel(&self.timers.single);
            self.skip(now, forward);
        } else {
            self.last_tap.set(Some(now));
            let tap = self.video.tap.clone();
            Timers::set(&self.timers.single, set_timeout(Duration::from_millis(DOUBLE_MS), move || tap()));
        }
    }

    fn grant(self: &Rc<Self>, event: &ResponderEvent) {
        self.start_x.set(event.location.x.0);
        self.mode.set(Mode::Pending);
        self.system.set(services::begin_levels());
        let state = Rc::downgrade(self);
        Timers::set(
            &self.timers.hold,
            set_timeout(HOLD, move || {
                let Some(state) = state.upgrade() else { return };
                if state.mode.get() == Mode::Pending {
                    state.mode.set(Mode::Hold);
                    Timers::cancel(&state.timers.linger);
                    batch(|| {
                        state.video.boost.set(true);
                        state.shown.set(Some(Shown::Boost));
                    });
                }
            }),
        );
    }

    fn moved(self: &Rc<Self>, event: &ResponderEvent) {
        let (dx, dy) = (event.gesture.delta.x.0, event.gesture.delta.y.0);
        let (width, height) = self.size.get();
        if self.mode.get() == Mode::Pending && dx.abs().max(dy.abs()) > SLOP {
            Timers::cancel(&self.timers.hold);
            Timers::cancel(&self.timers.linger);
            self.mode.set(if dx.abs() > dy.abs() {
                let from = (self.video.position)();
                Mode::Scrub { from, to: from, sought: 0.0 }
            } else {
                let brightness = !self.ahead(self.start_x.get());
                Mode::Level { brightness, from: self.level(brightness) }
            });
        }
        match self.mode.get() {
            Mode::Scrub { from, sought, .. } => {
                let of = (self.video.duration)();
                if of <= 0 || width <= 0.0 {
                    return;
                }
                let span = of.min(SCRUB_SPAN_MS) as f32;
                let to = (from + (dx / width * span) as i64).clamp(0, of);
                let sought = if event.timestamp - sought >= SCRUB_EVERY_MS {
                    (self.video.seek)(to);
                    event.timestamp
                } else {
                    sought
                };
                self.mode.set(Mode::Scrub { from, to, sought });
                self.shown.set(Some(Shown::Scrub { to, by: to - from, of }));
            }
            Mode::Level { brightness, from } => {
                let value = (from - dy / (height * 0.8).max(1.0)).clamp(0.0, 1.0);
                self.set_level(brightness, value);
                self.shown.set(Some(Shown::Level { brightness, value }));
            }
            Mode::Idle | Mode::Pending | Mode::Hold => {}
        }
    }

    fn ended(self: &Rc<Self>, event: &ResponderEvent, lifted: bool) {
        Timers::cancel(&self.timers.hold);
        match self.mode.replace(Mode::Idle) {
            Mode::Pending if lifted => self.tapped(event.timestamp),
            Mode::Hold => batch(|| {
                self.video.boost.set(false);
                self.shown.set(None);
            }),
            Mode::Scrub { to, .. } => {
                (self.video.seek)(to);
                self.linger();
            }
            Mode::Level { .. } => self.linger(),
            Mode::Idle | Mode::Pending => {}
        }
        if self.system.get() {
            services::end_levels();
        }
    }
}

/// The layer that takes a video's touches, over the picture.
pub(crate) fn layer(video: Video) -> impl IntoElement {
    let state = Rc::new(State {
        video,
        shown: signal(None),
        dim: signal(0.0),
        mode: Cell::new(Mode::Idle),
        size: Cell::new((0.0, 0.0)),
        start_x: Cell::new(0.0),
        system: Cell::new(false),
        last_tap: Cell::new(None),
        streak: Cell::new(None),
        timers: Timers::default(),
    });
    {
        let state = state.clone();
        cleanup(move || {
            if state.mode.get() == Mode::Hold {
                state.video.boost.try_set(false);
            }
        });
    }
    let (shown, dim) = (state.shown, state.dim);
    view()
        .absolute()
        .inset_0()
        .claim_touches(TouchClaim::on_start())
        .keep_touches(true)
        .on_layout({
            let state = state.clone();
            move |bounds: &Bounds<Points>| state.size.set((bounds.size.width.0, bounds.size.height.0))
        })
        .on_responder_grant({
            let state = state.clone();
            move |event: &ResponderEvent| state.grant(event)
        })
        .on_responder_move({
            let state = state.clone();
            move |event: &ResponderEvent| state.moved(event)
        })
        .on_responder_release({
            let state = state.clone();
            move |event: &ResponderEvent| state.ended(event, true)
        })
        .on_responder_terminate(move |event: &ResponderEvent| state.ended(event, false))
        .child(
            view()
                .absolute()
                .inset_0()
                .pointer_events(PointerEvents::None)
                .bg(|| tokens::ink(tokens::Ink::Stage))
                .opacity(move || dim.get()),
        )
        .child(feedback(shown))
}

fn ink() -> Hsla {
    theme().foreground.dark
}

fn card() -> View {
    view()
        .flex_row()
        .items_center()
        .gap_2()
        .px_4()
        .py_2()
        .rounded(|| tokens::corner(tokens::Corner::Large))
        .bg(|| tokens::ink(tokens::Ink::Stage).opacity(0.65))
        .text_color(ink)
}

fn label(text_of: impl Fn() -> String + 'static) -> Text {
    text(move || SharedString::from(text_of())).text_base().font_weight(FontWeight::SEMIBOLD).text_color(ink)
}

fn feedback(shown: Signal<Option<Shown>>) -> impl IntoElement {
    let scrub = move || match shown.get() {
        Some(Shown::Scrub { to, by, of }) => Some((to, by, of)),
        _ => None,
    };
    let level = move || match shown.get() {
        Some(Shown::Level { brightness, value }) => Some((brightness, value)),
        _ => None,
    };
    let skip = move || match shown.get() {
        Some(Shown::Skip { forward, ms }) => Some((forward, ms)),
        _ => None,
    };
    let top = move || px(20.0 + if store().immersive() { safe_area().top.0 } else { 0.0 });
    view()
        .absolute()
        .inset_0()
        .pointer_events(PointerEvents::None)
        .child(when(
            move || shown.get() == Some(Shown::Boost),
            move || {
                view()
                    .absolute()
                    .top(top)
                    .left(px(0.0))
                    .right(px(0.0))
                    .items_center()
                    .child(card().child(ui::icon(Icon::FastForward, 16.0)).child(label(|| format!("{BOOST}×"))))
            },
        ))
        .child(when(
            move || scrub().is_some(),
            move || {
                view().absolute().inset_0().items_center().justify_center().child(
                    card()
                        .flex_col()
                        .gap_1()
                        .px_5()
                        .py_3()
                        .child(
                            label(move || {
                                let (to, _, of) = scrub().unwrap_or_default();
                                format!(
                                    "{} / {}",
                                    format::shown(format::Shown::Clock(to)),
                                    format::shown(format::Shown::Clock(of))
                                )
                            })
                            .text_xl(),
                        )
                        .child(
                            label(move || {
                                let (_, by, _) = scrub().unwrap_or_default();
                                format!("{}{}s", if by < 0 { "−" } else { "+" }, by.abs() / 1000)
                            })
                            .text_sm()
                            .font_weight(FontWeight::MEDIUM)
                            .opacity(0.8),
                        ),
                )
            },
        ))
        .child(when(
            move || level().is_some(),
            move || {
                let value = move || level().map_or(0.0, |(_, value)| value);
                let glyph = move || match level() {
                    Some((true, _)) => Icon::Sun,
                    _ if value() <= 0.0 => Icon::Muted,
                    _ => Icon::Volume,
                };
                view().absolute().inset_0().items_center().justify_center().child(
                    card().gap_3().py_3().child(ui::icon_of(glyph, 20.0)).child(
                        view()
                            .w(px(140.0))
                            .h(px(4.0))
                            .rounded_full()
                            .bg(|| ink().opacity(0.3))
                            .child(view().h_full().rounded_full().bg(ink).w(move || px(140.0 * value()))),
                    ),
                )
            },
        ))
        .child(when(
            move || skip().is_some(),
            move || {
                let forward = move || skip().is_some_and(|(forward, _)| forward);
                view()
                    .absolute()
                    .top(px(0.0))
                    .bottom(px(0.0))
                    .w(relative(0.4))
                    .style_with(move |s| if forward() { s.right(px(0.0)) } else { s.left(px(0.0)) })
                    .items_center()
                    .justify_center()
                    .child(
                        card()
                            .child(ui::icon_of(move || if forward() { Icon::FastForward } else { Icon::Rewind }, 18.0))
                            .child(label(move || format!("{}s", skip().map_or(0, |(_, ms)| ms) / 1000))),
                    )
            },
        ))
}
