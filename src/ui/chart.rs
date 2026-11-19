//! The app's charts: a goal ring, bars per day and a calendar of days. Pages
//! hand them numbers and words; the look is here.

use std::f32::consts::TAU;

use nsh_base::{
    plot::{
        AppearKey, AxisPlacement, BandScale, BarCornerRadii, PlotMotion, Scale, TickFormat, arc, bar, grid, plot,
        plot_axis,
    },
    theme,
};
use nsh_core::{
    element::{RowAccessor, Rows, Timing},
    prelude::*,
};

use super::tokens::{self, motion};

fn timing(duration_ms: f32) -> Option<Timing> {
    Some(Timing { duration_ms, ..Timing::default() })
}

fn plot_motion() -> PlotMotion {
    PlotMotion {
        appear: timing(motion::BASE * 2.0),
        update: timing(motion::BASE),
        enter: timing(motion::INSTANT),
        exit: timing(motion::INSTANT),
        ..PlotMotion::default()
    }
}

/// The color of listening time, in charts and their keys.
pub fn listen_color() -> AdaptiveColor {
    tokens::listen()
}

/// The color of practice time.
pub fn practice_color() -> AdaptiveColor {
    tokens::practice()
}

/// The goal line and its key: quiet beside the two series.
pub fn goal_color() -> AdaptiveColor {
    theme().foreground.opacity(0.45)
}

/// A calendar day's shade, from nothing to the goal met.
fn heat_color(level: u8) -> AdaptiveColor {
    match level {
        0 => theme().muted,
        1 => tokens::listen().opacity(0.3),
        2 => tokens::listen().opacity(0.5),
        3 => tokens::listen().opacity(0.75),
        _ => tokens::listen(),
    }
}

/// A small square of a series' color, for a key beside its number.
pub fn swatch(color: fn() -> AdaptiveColor) -> View {
    view().size(px(8.0)).flex_shrink_0().rounded(px(2.0)).bg(color)
}

/// A ring filling toward a goal: listening then practice, as shares of the
/// goal (together at most a whole turn), with `center` inside.
pub fn goal_ring(
    shares: impl Fn() -> (f32, f32) + Copy + 'static,
    size: f32,
    thickness: f32,
    label: impl IntoReactive<SharedString>,
    center: impl IntoElement,
) -> View {
    let inner = px((size / 2.0 - thickness).max(0.0));
    let angles = move || {
        let (listen, practice) = shares();
        let (listen, practice) = (listen.max(0.0), practice.max(0.0));
        let total = listen + practice;
        let scale = if total > 1.0 { 1.0 / total } else { 1.0 };
        (TAU * listen * scale, TAU * (listen + practice) * scale)
    };
    // Practice is drawn under listening, from the start, so listening's
    // round end sits on it.
    let segment = move |end: fn((f32, f32)) -> f32, color: fn() -> AdaptiveColor| {
        arc()
            .end_angle(move || Radians(end(angles()).max(0.0001)))
            .inner_radius(inner)
            .corner_radius(px(thickness / 2.0))
            .fill_color(color)
    };
    view()
        .size(px(size))
        .flex_shrink_0()
        .items_center()
        .justify_center()
        .label(label)
        .child(
            plot()
                .data(Rows::from_columns(0, []))
                .interactive(false)
                .motion(plot_motion())
                .appear_generation(Some(AppearKey::from(1_u32)))
                .absolute()
                .inset_0()
                .child(arc().inner_radius(inner).fill_color(|| theme().accent))
                .child(segment(|(_, all)| all, practice_color))
                .child(segment(|(listen, _)| listen, listen_color)),
        )
        .child(center)
}

#[derive(Debug, Clone, PartialEq)]
pub struct DayBar {
    /// The text under the bar; empty for none.
    pub tick: SharedString,
    pub listen_min: f64,
    pub practice_min: f64,
}

/// Bars per day, listening under practice, with a line at the goal.
/// `on_hover` hears the bar under the pointer or the keys.
pub fn day_bars(
    days: impl Fn() -> Vec<DayBar> + Copy + 'static,
    goal_min: impl Fn() -> f64 + Copy + 'static,
    ticks: Vec<SharedString>,
    height: f32,
    label: SharedString,
    on_hover: impl Fn(Option<usize>) + 'static,
) -> impl IntoElement {
    let count = ticks.len();
    let top =
        move || days().iter().map(|day| day.listen_min + day.practice_min).fold(goal_min() * 1.15, f64::max).max(1.0);
    let rows = move || {
        let days = days();
        Rows::from_columns(
            days.len(),
            [
                ("listen".into(), days.iter().map(|day| day.listen_min).collect()),
                ("practice".into(), days.iter().map(|day| day.practice_min).collect()),
            ],
        )
    };
    let mut band = BandScale::default();
    band.padding_inner = Percentage(if count > 10 { 0.25 } else { 0.4 });
    band.max_band_width = Some(px(40.0));
    let radius = if count > 10 { 2.0 } else { 4.0 };
    let mut top_corners = BarCornerRadii::all(px(radius));
    top_corners.bottom_left = px(0.0);
    top_corners.bottom_right = px(0.0);
    plot()
        .data(rows)
        .x_scale(Scale::Band(band))
        .y_scale(move || Some(Scale::Linear { domain: Some([0.0, top()]), reverse: false }))
        .motion(plot_motion())
        .appear_generation(Some(AppearKey::from(count as u32)))
        .accessibility_label(label)
        .w_full()
        .h(px(height))
        .mb(px(20.0))
        .on_hover_change(move |index: &Option<u32>| on_hover(index.map(|i| i as usize)))
        .child(grid().y(move || Some(vec![top() / 2.0])).stroke_width(px(1.0)).stroke_color(|| theme().border))
        .child(
            bar()
                .value(RowAccessor::key("listen"))
                .stack("time")
                .inactive_opacity(Percentage(0.55))
                .fill_color(listen_color),
        )
        .child(
            bar()
                .value(RowAccessor::key("practice"))
                .stack("time")
                .corner_radii(top_corners)
                .inactive_opacity(Percentage(0.55))
                .fill_color(practice_color),
        )
        .child(grid().y(move || Some(vec![goal_min()])).stroke_width(px(1.5)).stroke_color(goal_color))
        .child(
            plot_axis()
                .placement(AxisPlacement::Bottom)
                .format(TickFormat::from_fn(move |value, _| {
                    ticks.get(value.round().max(0.0) as usize).cloned().unwrap_or_default()
                }))
                .label_class("text-xs text-muted-foreground pt-1.5"),
        )
}

pub const HEAT_CELL: f32 = 12.0;
pub const HEAT_GAP: f32 = 3.0;

#[derive(Debug, Clone, PartialEq)]
pub struct HeatDay {
    /// 0 for nothing, up to 4 for the goal met and more.
    pub level: u8,
    /// What the day says under the pointer.
    pub caption: SharedString,
}

/// A calendar of days, a column per week from Monday down, each day shaded
/// by how much was done. Days to come are `None`.
pub fn heatmap(
    weeks: Vec<[Option<HeatDay>; 7]>,
    label: impl IntoReactive<SharedString>,
    on_hover: impl Fn(Option<SharedString>) + Copy + 'static,
) -> View {
    const CELL: f32 = HEAT_CELL;
    const GAP: f32 = HEAT_GAP;
    // Spread over any width it is given beyond its weeks, so the last
    // column meets the edge.
    view()
        .flex_row()
        .justify_between()
        .gap(px(GAP))
        .label(label)
        .on_mouse_leave(move |_: &MouseEvent| on_hover(None))
        .children(weeks.into_iter().map(move |week| {
            view().gap(px(GAP)).children(week.into_iter().map(move |day| {
                let cell = view().size(px(CELL)).rounded(tokens::radius_sm_small);
                match day {
                    None => cell,
                    Some(HeatDay { level, caption }) => cell
                        .bg(move || heat_color(level))
                        .border_1()
                        .border_color(move || if level == 0 { theme().border } else { AdaptiveColor::TRANSPARENT })
                        .on_mouse_enter(move |_: &MouseEvent| on_hover(Some(caption.clone()))),
                }
            }))
        }))
}

/// The key under a heatmap: from nothing to the goal met.
pub fn heat_key(less: impl IntoReactive<SharedString>, more: impl IntoReactive<SharedString>) -> View {
    let step = |level: u8| {
        view()
            .size(px(10.0))
            .rounded(tokens::radius_sm_small)
            .bg(move || heat_color(level))
            .border_1()
            .border_color(move || if level == 0 { theme().border } else { AdaptiveColor::TRANSPARENT })
    };
    view()
        .flex_row()
        .items_center()
        .gap_1()
        .child(text(less).text_xs().text_color(|| theme().muted_foreground).mr_1())
        .children((0..=4).map(step))
        .child(text(more).text_xs().text_color(|| theme().muted_foreground).ml_1())
}
