//! Waveforms: the live one of what is being recorded, newest on the right,
//! and the whole of a recording being trimmed, the parts kept in `primary`
//! and the parts cut out faint on a band washed with the ink.

use listenook_core::media::capture::{self, Span};
use nsh_base::theme;
use nsh_core::{
    geometry::{Bounds, point, size},
    prelude::*,
};

use super::tokens;

/// How many 10 ms levels the live meter shows: the last 12 seconds.
pub(crate) const RECENT_LEVELS: usize = 1_200;

/// The width of a bar and the gap after it.
const BAR: f32 = 2.0;
const GAP: f32 = 1.5;

fn bar(painter: Painter, x: f32, height: f32, value: f32, width: f32) -> Painter {
    let tall = (value * height).max(2.0);
    let rect = Bounds { origin: point(px(x), px((height - tall) / 2.0)), size: size(px(width), px(tall)) };
    painter.round_rect(rect, px(width / 2.0))
}

/// The last 12 seconds of `levels` (10 ms each, oldest first) as bars that
/// grow from the middle, red while `live`, grey while paused.
pub(super) fn live_wave(levels: Signal<Vec<f32>>, live: impl Fn() -> bool + 'static) -> View {
    let area = signal(None::<(f32, f32)>);
    view()
        .w_full()
        .h(px(56.0))
        .on_layout(move |frame: &Bounds<Points>| area.set(Some((frame.size.width.0, frame.size.height.0))))
        .accessibility_elements_hidden(true)
        .child(
            canvas(move || {
                let Some((width, height)) = area.get() else {
                    return Painter::new();
                };
                let count = ((width + GAP) / (BAR + GAP)).floor().max(1.0) as usize;
                let shown = levels.with(|levels| {
                    let mut padded = vec![0.0; RECENT_LEVELS.saturating_sub(levels.len())];
                    padded.extend_from_slice(levels);
                    capture::bars(&padded, count)
                });
                let ink = color(if live() {
                    tokens::ink(tokens::Ink::Recording)
                } else {
                    theme().muted_foreground.opacity(0.6)
                });
                let mut painter = Painter::new().begin_path().fill_color(ink);
                for (index, value) in shown.iter().enumerate() {
                    painter = bar(painter, index as f32 * (BAR + GAP), height, *value, BAR);
                }
                painter.fill()
            })
            .absolute()
            .inset_0()
            .pointer_events(PointerEvents::None),
        )
}

/// The last 12 seconds of `levels` (10 ms each, oldest first) as bars that
/// grow from the middle, red while `live`, grey while paused.
pub struct LiveWave<P1> {
    pub levels: Signal<Vec<f32>>,
    pub live: P1,
}

impl<P1: Fn() -> bool + 'static> IntoElement for LiveWave<P1> {
    fn into_element(self) -> AnyElement {
        live_wave(self.levels, self.live).into_element()
    }
}

/// A whole recording to trim: `levels` (10 ms each) over `duration_ms`,
/// what `kept` keeps in `primary` and the rest faint on a washed band, and
/// a line where the preview is. A press or a drag along it calls `seek`
/// with the time under the pointer.
pub(super) fn waveform(
    levels: std::rc::Rc<Vec<f32>>,
    duration_ms: impl Fn() -> u64 + Copy + 'static,
    kept: impl Fn() -> Vec<Span> + 'static,
    position_ms: impl Fn() -> Option<u64> + 'static,
    seek: impl Fn(u64) + Copy + 'static,
) -> View {
    let area = signal(None::<(f32, f32)>);
    let time_at = move |x: f32| {
        let width = area.get_untracked().map_or(1.0, |(width, _)| width.max(1.0));
        ((x / width).clamp(0.0, 1.0) as f64 * duration_ms() as f64) as u64
    };
    view()
        .w_full()
        .h(px(96.0))
        .rounded(|| tokens::corner(tokens::Corner::Medium))
        .overflow_hidden()
        .border_1()
        .border_color(|| theme().border)
        .bg(|| theme().card)
        .on_layout(move |frame: &Bounds<Points>| area.set(Some((frame.size.width.0, frame.size.height.0))))
        .claim_touches(TouchClaim::on_start())
        .on_responder_grant(move |event: &ResponderEvent| seek(time_at(event.location.x.0)))
        .on_responder_move(move |event: &ResponderEvent| seek(time_at(event.location.x.0)))
        .accessibility_elements_hidden(true)
        .child(
            canvas(move || {
                let Some((width, height)) = area.get() else {
                    return Painter::new();
                };
                let duration = duration_ms().max(1);
                let x_of = |ms: u64| ms as f32 / duration as f32 * width;
                let kept = kept();
                // The parts cut out, as bands behind the bars.
                // A wash of the ink, so the band shows on light and dark cards alike.
                let mut painter = Painter::new().begin_path().fill_color(color(theme().foreground.opacity(0.07)));
                let mut at = 0;
                for span in kept.iter().chain(std::iter::once(&Span::new(duration, duration))) {
                    if span.start_ms > at {
                        let rect = Bounds {
                            origin: point(px(x_of(at)), px(0.0)),
                            size: size(px(x_of(span.start_ms) - x_of(at)), px(height)),
                        };
                        painter = painter.rect(rect);
                    }
                    at = at.max(span.end_ms);
                }
                painter = painter.fill();

                let count = ((width + GAP) / (BAR + GAP)).floor().max(1.0) as usize;
                let shown = capture::bars(&levels, count);
                let is_kept = |index: usize| {
                    let ms = ((index as f64 + 0.5) / count as f64 * duration as f64) as u64;
                    kept.iter().any(|span| span.contains(ms))
                };
                let inner = height - 16.0;
                for keep in [true, false] {
                    let ink = color(if keep { theme().primary } else { theme().muted_foreground.opacity(0.45) });
                    painter = painter.begin_path().fill_color(ink).translate(0.0, 8.0);
                    for (index, value) in shown.iter().enumerate().filter(|(index, _)| is_kept(*index) == keep) {
                        painter = bar(painter, index as f32 * (BAR + GAP), inner, *value, BAR);
                    }
                    painter = painter.fill().translate(0.0, -8.0);
                }
                if let Some(position) = position_ms() {
                    let x = x_of(position.min(duration)).clamp(0.0, width - 2.0);
                    painter = painter.fill_color(color(theme().foreground)).fill_rect(x, 0.0, 2.0, height);
                }
                painter
            })
            .absolute()
            .inset_0()
            .pointer_events(PointerEvents::None),
        )
}

/// A whole recording to trim: `levels` (10 ms each) over `duration_ms`,
/// what `kept` keeps in `primary` and the rest faint on a washed band, and
/// a line where the preview is. A press or a drag along it calls `seek`
/// with the time under the pointer.
pub struct Waveform<P1, P2, P3, P4> {
    pub levels: std::rc::Rc<Vec<f32>>,
    pub duration_ms: P1,
    pub kept: P2,
    pub position_ms: P3,
    pub seek: P4,
}

impl<
    P1: Fn() -> u64 + Copy + 'static,
    P2: Fn() -> Vec<Span> + 'static,
    P3: Fn() -> Option<u64> + 'static,
    P4: Fn(u64) + Copy + 'static,
> IntoElement for Waveform<P1, P2, P3, P4>
{
    fn into_element(self) -> AnyElement {
        waveform(self.levels, self.duration_ms, self.kept, self.position_ms, self.seek).into_element()
    }
}
