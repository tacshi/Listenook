//! Home's learning time: today against the daily goal, and the days before.

use listenook_core::{
    activity::{self, Day, NaiveDate, weekday_index},
    l10n::Lang,
};
use nsh_base::theme;
use nsh_core::prelude::*;

use crate::ui::{l, tr};
use crate::{
    pages::chrome::page_width,
    state::{activity::ActivityState, store},
    ui::{
        self, Icon, MenuChoice, Segmented, Size, card,
        chart::{self, DayBar, HeatDay},
        icon,
    },
};

pub(crate) const GOALS: &[u32] = &[10, 15, 20, 30, 45, 60];
const HEAT_WEEKS: u32 = 20;
/// The fewest weeks the calendar shows when it stacks under the bars, and
/// the most: a year.
const HEAT_WEEKS_STACKED: (u32, u32) = (12, 52);
/// The card's padding and border on both sides.
const CARD_INSET: f32 = 2.0 * (16.0 + 1.0);
/// Below this content width, the activity's bars and calendar stack.
const SIDE_BY_SIDE: f32 = 760.0;
/// From this content width, Today stands beside Continue.
const BESIDE: f32 = 720.0;
const MAX_WIDTH: f32 = 960.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Range {
    Week,
    Month,
}

impl Range {
    fn days(self) -> u32 {
        match self {
            Range::Week => 7,
            Range::Month => 30,
        }
    }
}

fn content_width() -> f32 {
    page_width().min(MAX_WIDTH) - 2.0 * ui::PAGE_INSET
}

/// Whether Today stands beside Continue rather than above it.
pub(crate) fn beside() -> bool {
    content_width() >= BESIDE
}

/// "18 min", "1 h 5 min": whole minutes, rounded down.
pub(crate) fn minutes(secs: u32) -> String {
    let minutes = secs / 60;
    let (hours, minutes) = (minutes / 60, minutes % 60);
    match (store().lang(), hours) {
        (Lang::Zh, 0) => format!("{minutes} 分钟"),
        (Lang::Zh, _) => format!("{hours} 小时 {minutes} 分钟"),
        (Lang::En, 0) => format!("{minutes} min"),
        (Lang::En, _) => format!("{hours} h {minutes} min"),
    }
}

fn streak_words(days: u32) -> String {
    match store().lang() {
        Lang::Zh => format!("连续 {days} 天达成"),
        Lang::En if days == 1 => "1-day streak".to_owned(),
        Lang::En => format!("{days}-day streak"),
    }
}

fn goal_words(goal_min: u32) -> String {
    match store().lang() {
        Lang::Zh => format!("目标 {goal_min} 分钟"),
        Lang::En => format!("of {goal_min} min"),
    }
}

fn to_go_words(secs: u32) -> String {
    let left = secs.div_ceil(60).max(1);
    match store().lang() {
        Lang::Zh => format!("还差 {left} 分钟"),
        Lang::En => format!("{left} min to go"),
    }
}

fn day_words(day: NaiveDate) -> String {
    if day == ActivityState::get().today() {
        return tr("Today").to_string();
    }
    match store().lang() {
        Lang::Zh => {
            const WEEKDAYS: [&str; 7] = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"];
            format!("{} {}", day.format("%-m月%-d日"), WEEKDAYS[weekday_index(day) as usize])
        }
        Lang::En => day.format("%a, %b %-d").to_string(),
    }
}

fn weekday_tick(day: NaiveDate) -> SharedString {
    if day == ActivityState::get().today() {
        return tr("Today");
    }
    match store().lang() {
        Lang::Zh => ["一", "二", "三", "四", "五", "六", "日"][weekday_index(day) as usize].into(),
        Lang::En => day.format("%a").to_string().into(),
    }
}

fn day_caption(day: NaiveDate, time: Day) -> SharedString {
    let mut caption = format!("{} · {}", day_words(day), minutes(time.total_s()));
    if time.total_s() >= 60 {
        caption.push_str(&format!(
            " ({} {} · {} {})",
            tr("Listening"),
            minutes(time.listen_s),
            tr("Practice"),
            minutes(time.practice_s)
        ));
    }
    caption.into()
}

/// The calendar's caption: the day and its time, then the split, on two
/// lines so it stays within the calendar's width.
fn heat_caption(day: NaiveDate, time: Day) -> SharedString {
    let head = format!("{} · {}", day_words(day), minutes(time.total_s()));
    if time.total_s() < 60 {
        return head.into();
    }
    format!("{head}\n{} {} · {} {}", tr("Listening"), minutes(time.listen_s), tr("Practice"), minutes(time.practice_s))
        .into()
}

fn days_words(days: u32) -> String {
    match store().lang() {
        Lang::Zh => format!("{days} 天"),
        Lang::En if days == 1 => "1 day".to_owned(),
        Lang::En => format!("{days} days"),
    }
}

/// The width of a calendar of `weeks` columns.
fn calendar_width(weeks: u32) -> f32 {
    weeks as f32 * (chart::HEAT_CELL + chart::HEAT_GAP) - chart::HEAT_GAP
}

/// As many weeks as fit `width`, so a stacked calendar spans the card.
fn weeks_fitting(width: f32) -> u32 {
    let (fewest, most) = HEAT_WEEKS_STACKED;
    (((width + chart::HEAT_GAP) / (chart::HEAT_CELL + chart::HEAT_GAP)).floor() as u32).clamp(fewest, most)
}

fn goal_s() -> u32 {
    store().daily_goal_minutes() * 60
}

/// Whether there is history worth a chart: time on two days or more.
pub(crate) fn has_history() -> bool {
    ActivityState::get().with(|log| log.active_days() >= 2)
}

/// Today against the daily goal. `wide` lays it out as a column beside
/// Continue; otherwise as a row.
pub(crate) fn today_card(wide: impl Fn() -> bool + Copy + 'static) -> impl IntoElement {
    let store = store();
    let today = computed(move || {
        let activity = ActivityState::get();
        let day = activity.today();
        activity.with(|log| log.on(day))
    });
    let goal = move || store.daily_goal_minutes();
    let streak = computed(move || {
        let activity = ActivityState::get();
        let day = activity.today();
        activity.with(|log| log.streak(day, goal_s()))
    });
    let shares = move || {
        let (day, goal_s) = (today.get(), (goal() * 60).max(1) as f32);
        (day.listen_s as f32 / goal_s, day.practice_s as f32 / goal_s)
    };
    let met = move || today.get().total_s() >= goal() * 60;
    let ring_label = move || -> SharedString {
        format!("{} {}, {}", tr("Today"), minutes(today.get().total_s()), goal_words(goal())).into()
    };
    let open = signal(false);
    let goal_menu = ui::menu_with(open, ui::menu_trigger(Icon::Target, tr("Daily goal"), Size::Sm, open)).children(
        GOALS.iter().map(move |&minutes| MenuChoice {
            label: move || SharedString::from(goal_choice(minutes)),
            checked: move || store.daily_goal_minutes() == minutes,
            on_select: move || store.act(crate::state::Action::SetDailyGoalMinutes(minutes)),
        }),
    );
    let key = move |color: fn() -> AdaptiveColor, name: &'static str, secs: fn(Day) -> u32| {
        view()
            .flex_row()
            .items_center()
            .gap_2()
            .child(chart::Swatch { color })
            .child(text(l(name)).flex_shrink_0().number_of_lines(1).text_sm().text_color(|| theme().muted_foreground))
            .child(
                text(move || SharedString::from(minutes(secs(today.get()))))
                    .flex_1()
                    .text_right()
                    .text_sm()
                    .tabular_nums()
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(|| theme().foreground),
            )
    };
    let keys = move || {
        view().gap_1p5().child(key(chart::listen_color, "Listening", |day| day.listen_s)).child(key(
            chart::practice_color,
            "Practice",
            |day| day.practice_s,
        ))
    };
    let status = move || -> SharedString {
        let (total, goal_s) = (today.get().total_s(), goal() * 60);
        if total >= goal_s {
            tr("Goal met")
        } else if total < 60 {
            tr("Play something to start today's minutes.")
        } else {
            to_go_words(goal_s - total).into()
        }
    };
    let status_line = move || {
        view()
            .flex_row()
            .items_center()
            .gap_1p5()
            .child(when(
                move || streak.get() > 0,
                move || {
                    view()
                        .flex_row()
                        .items_center()
                        .gap_1()
                        .text_color(|| ui::tokens::ink(ui::tokens::Ink::Warning))
                        .child(icon(Icon::Flame, 14.0))
                        .child(
                            text(move || SharedString::from(streak_words(streak.get())))
                                .text_xs()
                                .font_weight(FontWeight::MEDIUM)
                                .text_color(|| theme().foreground),
                        )
                },
            ))
            .child(when(move || streak.get() > 0, || text("·").text_xs().text_color(|| theme().muted_foreground)))
            .child(text(status).flex_1().min_w(px(0.0)).text_xs().number_of_lines(2).text_color(move || {
                if met() { ui::tokens::ink(ui::tokens::Ink::Success) } else { theme().muted_foreground }
            }))
    };
    let header = view()
        .flex_row()
        .items_center()
        .justify_between()
        .min_h(px(Size::Sm.height()))
        .child(
            text(l("Today"))
                .text_base()
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(|| theme().foreground)
                .role(AccessibilityRole::Header),
        )
        .child(goal_menu);
    let center = move |big: bool| {
        view()
            .items_center()
            .child(
                text(move || SharedString::from((today.get().total_s() / 60).to_string()))
                    .style_with(move |s| if big { s.text_2xl() } else { s.text_xl() })
                    .font_weight(FontWeight::SEMIBOLD)
                    .tabular_nums()
                    .text_color(|| theme().foreground),
            )
            .child(
                text(move || SharedString::from(goal_words(goal())))
                    .text_xs()
                    .tabular_nums()
                    .text_color(|| theme().muted_foreground),
            )
    };
    // Beside Continue it is as tall as Continue, its content centered.
    let body = card().flex_1().p_4().justify_center().child(dynamic(move || {
        let wide = wide();
        untracked(|| {
            if wide {
                view()
                    .gap_3()
                    .child(
                        view()
                            .flex_row()
                            .items_center()
                            .gap_3()
                            .child(chart::GoalRing {
                                shares,
                                size: 96.0,
                                thickness: 10.0,
                                label: ring_label,
                                center: center(true),
                            })
                            .child(view().flex_1().min_w(px(0.0)).child(keys())),
                    )
                    .child(status_line())
                    .into_element()
            } else {
                view()
                    .flex_row()
                    .items_center()
                    .gap_4()
                    .child(chart::GoalRing {
                        shares,
                        size: 88.0,
                        thickness: 9.0,
                        label: ring_label,
                        center: center(false),
                    })
                    .child(view().flex_1().min_w(px(0.0)).gap_3().child(keys()).child(status_line()))
                    .into_element()
            }
        })
    }));
    view().flex_1().gap_3().child(header).child(body)
}

pub(crate) fn goal_choice(minutes: u32) -> String {
    match store().lang() {
        Lang::Zh => format!("每天 {minutes} 分钟"),
        Lang::En => format!("{minutes} min a day"),
    }
}

/// The days before today: bars for the last week or month, and a calendar
/// of the last weeks.
pub(crate) fn activity_card() -> impl IntoElement {
    let store = store();
    let range = signal(Range::Week);
    let hovered = signal(None::<usize>);
    let heat_hovered = signal(None::<SharedString>);
    let today = computed(|| ActivityState::get().today());
    let goal = computed(move || store.daily_goal_minutes());
    let days = computed(move || {
        let (today, n) = (today.get(), range.get().days());
        ActivityState::get().with(|log| log.days(today, n))
    });
    let total = move || days.with(|days| days.iter().map(|(_, day)| day.total_s()).sum::<u32>());
    let summary = move || -> SharedString {
        let n = range.get().days();
        let total = total();
        let span = match (store.lang(), range.get()) {
            (Lang::Zh, Range::Week) => "最近 7 天".to_owned(),
            (Lang::Zh, Range::Month) => "最近 30 天".to_owned(),
            (Lang::En, Range::Week) => "in the last 7 days".to_owned(),
            (Lang::En, Range::Month) => "in the last 30 days".to_owned(),
        };
        let average = minutes(total / n);
        match store.lang() {
            Lang::Zh => format!("{span} · 平均每天 {average}"),
            Lang::En => format!("{span} · {average} a day on average"),
        }
        .into()
    };
    let bars = move || {
        days.with(|days| {
            days.iter()
                .map(|(_, day)| DayBar {
                    tick: SharedString::default(),
                    listen_min: f64::from(day.listen_s) / 60.0,
                    practice_min: f64::from(day.practice_s) / 60.0,
                })
                .collect::<Vec<_>>()
        })
    };
    let chart = dynamic(move || {
        let (range, today) = (range.get(), today.get());
        untracked(move || {
            let n = range.days();
            let ticks: Vec<SharedString> = days.with(|days| {
                days.iter()
                    .enumerate()
                    .map(|(index, (day, _))| match range {
                        Range::Week => weekday_tick(*day),
                        Range::Month if (n as usize - 1 - index).is_multiple_of(7) => {
                            if *day == today {
                                tr("Today")
                            } else {
                                day.format("%-m/%-d").to_string().into()
                            }
                        }
                        Range::Month => SharedString::default(),
                    })
                    .collect()
            });
            let label = SharedString::from(match (store.lang(), range) {
                (Lang::Zh, Range::Week) => "最近 7 天的学习时间".to_owned(),
                (Lang::Zh, Range::Month) => "最近 30 天的学习时间".to_owned(),
                (Lang::En, Range::Week) => "Learning time, last 7 days".to_owned(),
                (Lang::En, Range::Month) => "Learning time, last 30 days".to_owned(),
            });
            chart::day_bars(bars, move || f64::from(goal.get()), ticks, 148.0, label, move |index| hovered.set(index))
                .into_element()
        })
    });
    let caption = move || -> Option<SharedString> {
        let index = hovered.get()?;
        days.with(|days| days.get(index).map(|(day, time)| day_caption(*day, *time)))
    };
    let legend = move || {
        view()
            .flex_row()
            .flex_wrap()
            .items_center()
            .gap_x_4()
            .gap_y_1()
            .child(legend_item(chart::Swatch { color: chart::listen_color }, l("Listening")))
            .child(legend_item(chart::Swatch { color: chart::practice_color }, l("Practice")))
            .child(legend_item(view().w(px(12.0)).h(px(2.0)).rounded_full().bg(chart::goal_color), l("Daily goal")))
    };
    let bars_column = view()
        .flex_1()
        .min_w(px(0.0))
        .gap_3()
        .child(
            view()
                .gap_0p5()
                .child(
                    text(move || SharedString::from(minutes(total())))
                        .text_lg()
                        .font_weight(FontWeight::SEMIBOLD)
                        .tabular_nums()
                        .text_color(|| theme().foreground),
                )
                .child(text(summary).text_xs().tabular_nums().text_color(|| theme().muted_foreground)),
        )
        .child(chart)
        .child(
            view().min_h(px(20.0)).justify_center().child(
                when(
                    move || caption().is_some(),
                    move || {
                        text(move || caption().unwrap_or_default())
                            .text_xs()
                            .tabular_nums()
                            .number_of_lines(1)
                            .text_color(|| theme().foreground)
                    },
                )
                .otherwise(legend),
            ),
        );
    let side_by_side = move || content_width() >= SIDE_BY_SIDE;
    let heat_weeks = move || if side_by_side() { HEAT_WEEKS } else { weeks_fitting(content_width() - CARD_INSET) };
    let calendar = dynamic(move || {
        let (weeks, today, goal_s) = (heat_weeks(), today.get(), goal.get() * 60);
        let log = ActivityState::get().log();
        untracked(move || {
            let start = today - activity::Days::new(u64::from(weekday_index(today) + 7 * (weeks - 1)));
            let totals = log.days(today, (today - start).num_days() as u32 + 1);
            let columns: Vec<[Option<HeatDay>; 7]> = totals
                .chunks(7)
                .map(|week| {
                    let mut column: [Option<HeatDay>; 7] = Default::default();
                    for (slot, (day, time)) in column.iter_mut().zip(week) {
                        let ratio = time.total_s() as f32 / goal_s.max(1) as f32;
                        let level = match ratio {
                            r if r <= 0.0 => 0,
                            r if r < 0.34 => 1,
                            r if r < 0.67 => 2,
                            r if r < 1.0 => 3,
                            _ => 4,
                        };
                        *slot = Some(HeatDay { level, caption: heat_caption(*day, *time) });
                    }
                    column
                })
                .collect();
            let active = totals.iter().filter(|(_, time)| time.total_s() > 0).count();
            let label = SharedString::from(match store.lang() {
                Lang::Zh => format!("最近 {weeks} 周的学习日历，{active} 天有学习"),
                Lang::En => format!("Learning calendar, last {weeks} weeks, {active} days with learning"),
            });
            chart::heatmap(columns, label, move |caption| heat_hovered.set(caption)).into_element()
        })
    });
    // The calendar's period in three numbers, pinned to the column's foot so
    // they line up with the bars' key.
    let period = computed(move || {
        let (weeks, today, goal_s) = (heat_weeks(), today.get(), goal.get() * 60);
        let start = today - activity::Days::new(u64::from(weekday_index(today) + 7 * (weeks - 1)));
        let totals = ActivityState::get().with(|log| log.days(today, (today - start).num_days() as u32 + 1));
        let learned = totals.iter().filter(|(_, time)| time.total_s() > 0).count() as u32;
        let met: Vec<bool> = totals.iter().map(|(_, time)| time.total_s() >= goal_s).collect();
        let at_goal = met.iter().filter(|met| **met).count() as u32;
        let best = met.split(|met| !met).map(<[bool]>::len).max().unwrap_or(0) as u32;
        (learned, at_goal, best)
    });
    let stat = move |name: &'static str, value: fn((u32, u32, u32)) -> u32| {
        view()
            .flex_1()
            .min_w(px(0.0))
            .gap_0p5()
            .child(
                text(move || SharedString::from(days_words(value(period.get()))))
                    .text_sm()
                    .font_weight(FontWeight::SEMIBOLD)
                    .tabular_nums()
                    .text_color(|| theme().foreground),
            )
            .child(text(l(name)).text_xs().number_of_lines(1).text_color(|| theme().muted_foreground))
    };
    let stats = view()
        .flex_row()
        .gap_3()
        .child(stat("Days learned", |(learned, _, _)| learned))
        .child(stat("Days at goal", |(_, at_goal, _)| at_goal))
        .child(stat("Best streak", |(_, _, best)| best));
    // As wide as the calendar, whatever its caption says, so nothing beside
    // it moves.
    let calendar_column = view()
        .gap_3()
        .child(
            text(move || -> SharedString {
                match store.lang() {
                    Lang::Zh => format!("最近 {} 周", heat_weeks()).into(),
                    Lang::En => format!("Last {} weeks", heat_weeks()).into(),
                }
            })
            .text_xs()
            .font_weight(FontWeight::MEDIUM)
            .text_color(|| theme().muted_foreground),
        )
        .child(calendar)
        .child(
            view().min_h(px(32.0)).justify_start().child(
                when(
                    move || heat_hovered.with(Option::is_some),
                    move || {
                        text(move || heat_hovered.get().unwrap_or_default())
                            .text_xs()
                            .tabular_nums()
                            .number_of_lines(2)
                            .text_color(|| theme().foreground)
                    },
                )
                .otherwise(|| chart::HeatKey { less: l("Less"), more: l("More") }),
            ),
        );
    let calendar_column = view()
        .flex_shrink_0()
        .gap_5()
        .justify_between()
        .style_with(move |s| if side_by_side() { s.w(px(calendar_width(heat_weeks()))) } else { s })
        .child(calendar_column)
        .child(stats);
    let header = view()
        .flex_row()
        .items_center()
        .justify_between()
        .gap_3()
        .child(
            text(l("Activity"))
                .text_base()
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(|| theme().foreground)
                .role(AccessibilityRole::Header),
        )
        .child(Segmented {
            options: vec![(Range::Week, "Week"), (Range::Month, "Month")],
            value: move || range.get(),
            on_change: move |next| {
                hovered.set(None);
                range.set(next);
            },
        });
    view().gap_3().child(header).child(
        card()
            .p_4()
            .style_with(move |s| if side_by_side() { s.flex_row().gap_6() } else { s.gap_5() })
            .child(bars_column)
            .child(when(side_by_side, || view().w(px(1.0)).self_stretch().bg(|| theme().border)))
            .child(calendar_column),
    )
}

fn legend_item(mark: impl IntoElement, name: impl IntoReactive<SharedString>) -> View {
    view()
        .flex_row()
        .items_center()
        .gap_1p5()
        .child(mark)
        .child(text(name).text_xs().text_color(|| theme().muted_foreground))
}
