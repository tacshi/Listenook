use listenook_core::{
    dictation::{self, DictationWord},
    format::clock,
};
use nsh_base::theme;
use nsh_core::prelude::*;

use super::review::{Practice, Review, Side};
use crate::{
    state::{l, tr},
    ui::{
        self, Icon, Size, Status, Variant, badge, field, hint, icon, icon_text_button, segmented, select, text_area,
        tokens,
    },
};

pub(super) fn start(review: Review, practice: Practice) {
    let target = untracked(|| review.target()).or(Some(0));
    batch(|| {
        review.practice.set(practice);
        review.side.set(Side::Practice);
    });
    match (practice, target) {
        (Practice::Mimic, Some(index)) => {
            if review.repeating.get_untracked().is_none() {
                review.toggle_repeat(index);
            }
        }
        (Practice::Dictation, Some(index)) => {
            review.repeating.set(None);
            review.replay_once(index);
        }
        _ => {}
    }
}

pub(super) fn stop(review: Review) {
    batch(|| {
        review.practice.set(Practice::None);
        review.repeating.set(None);
        review.paused.set(true);
    });
}

pub(super) fn practice_panel(review: Review) -> impl IntoElement {
    let heading = move || -> SharedString {
        match review.target().and_then(|index| review.segment(index).map(|segment| (index, segment))) {
            Some((index, segment)) => format!("{} {} · {}", tr("Sentence"), index + 1, clock(segment.start_ms)).into(),
            None => tr("Select a sentence to practice."),
        }
    };
    scroll().flex_1().child(
        view()
            .p_4()
            .gap_4()
            .child(segmented(
                vec![(Practice::Mimic, "Mimic"), (Practice::Dictation, "Type answer")],
                move || {
                    if review.practice.get() == Practice::Dictation { Practice::Dictation } else { Practice::Mimic }
                },
                move |practice| start(review, practice),
            ))
            .child(text(heading).text_sm().font_weight(FontWeight::SEMIBOLD).text_color(|| theme().foreground))
            .child(dynamic(move || {
                let practice = review.practice.get();
                untracked(|| match practice {
                    Practice::Dictation => dictation_panel(review).into_element(),
                    _ => mimic_panel(review).into_element(),
                })
            })),
    )
}

fn dictation_panel(review: Review) -> impl IntoElement {
    let answer = signal(String::new());
    let result = signal(None::<Vec<DictationWord>>);
    let pinned = signal(untracked(|| review.target()));
    let target = move || pinned.get().and_then(|index| review.segment(index));
    let supported = move || {
        target().is_some_and(|segment| dictation::supports_dictation(&segment.text, segment.language.as_deref()))
    };
    let begin = move |index: usize| {
        batch(|| {
            pinned.set(Some(index));
            answer.set(String::new());
            result.set(None);
            review.revealed.set(None);
        });
    };
    effect(move || {
        let live = review.target();
        untracked(|| {
            let untouched = answer.with(|a| a.trim().is_empty()) && result.with(Option::is_none);
            let replaying = review.stop_at.get().is_some();
            if untouched && !replaying && live != pinned.get() {
                pinned.set(live);
            }
        });
    });
    let check = move || {
        let (Some(segment), true) = (untracked(target), untracked(supported)) else {
            return;
        };
        if answer.with_untracked(|a| a.trim().is_empty()) {
            return;
        }
        let words = dictation::compare(&segment.text, &answer.get_untracked());
        batch(|| {
            review.paused.set(true);
            if dictation::is_correct(&words) {
                review.revealed.set(Some(segment.id.clone()));
            }
            result.set(Some(words));
        });
    };
    let next = move || {
        let next = pinned.get_untracked().map_or(0, |index| index + 1);
        if review.segment(next).is_some() {
            begin(next);
            review.replay_once(next);
        }
    };
    let submit = move || {
        if result.with_untracked(|r| r.as_ref().is_some_and(|words| dictation::is_correct(words))) {
            next();
        } else {
            check();
        }
    };
    on_key_with("mod+enter", KeyOptions { when: nsh_core::keymap::When::Always, ..KeyOptions::default() }, move |_| {
        check()
    });
    view()
        .gap_3()
        .child(
            text_area(answer, l("Type what you hear"))
                .auto_correct(false)
                .auto_capitalize(AutoCapitalize::None)
                .submit_behavior(SubmitBehavior::Submit)
                .return_key_type(ReturnKeyType::Done)
                .on_submit(move |_: &str| submit())
                .auto_focus(true),
        )
        .child(
            view()
                .flex_row()
                .flex_wrap()
                .items_center()
                .gap_2()
                .child(
                    icon_text_button(Variant::Primary, Size::Md, Icon::Check, l("Check"))
                        .disabled(move || !supported() || answer.with(|a| a.trim().is_empty()))
                        .on_press(check),
                )
                .child(icon_text_button(Variant::Outline, Size::Md, Icon::Refresh, l("Replay")).on_press(move || {
                    if let Some(index) = pinned.get_untracked() {
                        review.replay_once(index);
                    }
                }))
                .child(icon_text_button(Variant::Ghost, Size::Md, Icon::SkipForward, l("Next")).on_press(next)),
        )
        .child(when(move || !supported(), || hint(l("Word checking supports English only."))))
        .child(dynamic(move || {
            let Some(words) = result.get() else {
                return view().into_element();
            };
            untracked(|| verdict(&words).into_element())
        }))
}

fn verdict(words: &[DictationWord]) -> impl IntoElement {
    let correct = dictation::is_correct(words);
    let entrance = motion().entering(if correct { MotionPreset::FadeInUp } else { MotionPreset::Shake });
    let word = |label: String, wrong: bool| {
        text(label).text_sm().text_color(move || if wrong { theme().destructive } else { theme().foreground })
    };
    view()
        .bind_motion(&entrance)
        .gap_2()
        .child(
            view()
                .flex_row()
                .items_center()
                .gap_2()
                .text_color(move || if correct { tokens::success() } else { theme().destructive })
                .child(icon(if correct { Icon::Check } else { Icon::Close }, 16.0))
                .child(
                    text(if correct { tr("Matches transcript") } else { tr("Listen again and retry.") })
                        .text_sm()
                        .font_weight(FontWeight::MEDIUM),
                ),
        )
        .child(when(move || !correct, {
            let words = words.to_vec();
            move || {
                view().flex_row().flex_wrap().gap_1().children(words.iter().map(|w| match w {
                    DictationWord::Matching(expected) => word(expected.clone(), false).into_element(),
                    DictationWord::Different(_, actual) => word(actual.clone(), true).underline().into_element(),
                    DictationWord::Missing(_) => word("…".into(), true).font_weight(FontWeight::BOLD).into_element(),
                    DictationWord::Extra(actual) => word(actual.clone(), true).line_through().into_element(),
                }))
            }
        }))
}

fn mimic_panel(review: Review) -> impl IntoElement {
    let store = review.store;
    let target = move || review.target().and_then(|index| review.segment(index));
    let goal = move || store.setting(|s| s.mimic_rep_goal);
    let hidden = move || review.blind() && target().is_none_or(|segment| review.revealed.get() != Some(segment.id));
    view()
        .gap_4()
        .child(ui::veil(hidden, move || {
            view()
                .gap_2()
                .child(
                    text(move || target().map(|segment| SharedString::from(segment.text)).unwrap_or_default())
                        .text_base()
                        .line_height(nsh_core::LineHeight::Multiple(1.5))
                        .text_color(|| theme().foreground),
                )
                .child(when(
                    move || target().is_some_and(|segment| segment.has_translation()),
                    move || {
                        text(move || {
                            target().and_then(|s| s.translated_text).map(SharedString::from).unwrap_or_default()
                        })
                        .text_sm()
                        .text_color(|| theme().muted_foreground)
                    },
                ))
        }))
        .child(
            view()
                .flex_row()
                .items_center()
                .gap_2()
                .child(badge(
                    move || -> SharedString { format!("{} {}/{}", tr("Reps"), review.reps.get(), goal()).into() },
                    move || if review.waiting.get() { Status::Active } else { Status::Neutral },
                ))
                .child(when(move || review.waiting.get(), || hint(l("Your turn…")))),
        )
        .child(
            view()
                .flex_row()
                .gap_3()
                .child(
                    field(
                        l("Reps"),
                        select(
                            "Target reps",
                            [1, 2, 3, 5, 10, 20, 30]
                                .iter()
                                .map(|n| (n.to_string().into(), format!("{n}×").into()))
                                .collect(),
                            move || SharedString::from(goal().to_string()),
                            move |value| {
                                let goal = value.parse().unwrap_or(3);
                                store.update_settings(|s| s.mimic_rep_goal = goal);
                                review.reps.update(|reps| *reps = (*reps).min(goal));
                            },
                        ),
                    )
                    .flex_1(),
                )
                .child(
                    field(
                        l("Pause"),
                        select(
                            "Pause",
                            [0, 1, 2, 3, 5, 10]
                                .iter()
                                .map(|n| {
                                    (n.to_string().into(), if *n == 0 { tr("Auto") } else { format!("{n} s").into() })
                                })
                                .collect(),
                            move || SharedString::from(store.setting(|s| s.mimic_pause_seconds).to_string()),
                            move |value| store.update_settings(|s| s.mimic_pause_seconds = value.parse().unwrap_or(0)),
                        ),
                    )
                    .flex_1(),
                ),
        )
        .child(hint(l("Each sentence plays, then waits for you to say it. Press a sentence to practice it.")))
}
