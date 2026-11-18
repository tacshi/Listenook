use listenook_core::{
    dictation::{self, DictationWord},
    format::clock,
};
use nsh_base::theme;
use nsh_core::prelude::*;

use super::review::{Practice, Review, Side};
use crate::{
    state::{l, store, tr},
    ui::{
        self, Icon, Size, Status, Variant, badge, checkbox, field, hint, icon, icon_text_button, segmented, select,
        text_area, tokens,
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
            } else {
                review.repeat_one(index);
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
    let activity = store().activity;
    effect(move || {
        let on = review.practice.get() != Practice::None;
        untracked(|| activity.set_practicing(on));
    });
    cleanup(move || activity.set_practicing(false));
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

/// How long a correct answer stays up before Auto next moves on.
const AUTO_NEXT_AFTER: std::time::Duration = std::time::Duration::from_millis(1500);

fn dictation_panel(review: Review) -> impl IntoElement {
    let answer = signal(String::new());
    let result = signal(None::<Vec<DictationWord>>);
    effect(move || {
        answer.with(|_| ());
        untracked(|| store().activity.touch());
    });
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
    let solved = move || result.with(|r| r.as_ref().is_some_and(|words| dictation::is_correct(words)));
    let auto_replay = move || store().setting(|s| s.dictation_auto_replay);
    let auto_next = move || store().setting(|s| s.dictation_auto_next);
    effect(move || {
        let relisten = pinned.get().filter(|_| auto_replay() && !solved());
        untracked(|| {
            if review.relisten.get() != relisten {
                review.relisten.set(relisten);
            }
        });
    });
    cleanup(move || review.relisten.set(None));
    let advance = stored(None::<Spawned<()>>);
    cleanup(move || {
        if let Some(task) = advance.replace(None) {
            task.cancel();
        }
    });
    let next = move || {
        if let Some(task) = advance.replace(None) {
            task.cancel();
        }
        let next = review.next_kept(pinned.get_untracked().map_or(0, |index| index + 1));
        if let Some(next) = next {
            begin(next);
            review.replay_once(next);
        }
    };
    let field = element_ref();
    // The answer as checked, and the caret put after the check: typing or
    // moving the caret takes the marks off.
    let checked_text = stored(String::new());
    let placed = stored(None::<u32>);
    let refocus = stored(false);
    let check = move || {
        let (Some(segment), true) = (untracked(target), untracked(supported)) else {
            return;
        };
        let typed = answer.get_untracked();
        if typed.trim().is_empty() {
            return;
        }
        store().activity.touch();
        let words = dictation::compare(&segment.text, &typed);
        let correct = dictation::is_correct(&words);
        let again = !correct && untracked(auto_replay);
        let at = dictation::first_fix(&typed, &words).unwrap_or(typed.len());
        let caret = typed[..at].encode_utf16().count() as u32;
        checked_text.with(|text| *text = typed);
        placed.with(|placed| *placed = Some(caret));
        refocus.with(|once| *once = true);
        batch(|| {
            if !again {
                review.paused.set(true);
            }
            if correct {
                review.answered.update(|answered| {
                    answered.insert(segment.id.clone());
                });
            }
            result.set(Some(words));
        });
        field.focus();
        field.set_selection(caret, caret);
        if again && let Some(index) = pinned.get_untracked() {
            review.replay_once(index);
        }
        if correct && untracked(auto_next) {
            let at = pinned.get_untracked();
            let task = spawn(async move {
                timer(AUTO_NEXT_AFTER).await;
                advance.replace(None);
                if pinned.get_untracked() == at && untracked(solved) {
                    next();
                }
            });
            if let Some(earlier) = advance.replace(Some(task)) {
                earlier.cancel();
            }
        }
    };
    let checked = computed(move || result.with(Option::is_some));
    // Back to typing where the caret is: the marks go until the next check.
    let edit = move || {
        if !untracked(|| checked.get()) {
            return;
        }
        if let Some(task) = advance.replace(None) {
            task.cancel();
        }
        result.set(None);
    };
    effect(move || {
        let changed = answer.with(|typed| checked_text.with(|text| text != typed));
        if changed {
            untracked(edit);
        }
    });
    let submit = move || {
        if untracked(solved) {
            next();
        } else if untracked(|| checked.get()) {
            edit();
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
            // One input throughout, keeping its focus and caret; checked, it
            // goes see-through over its words marked under it (covered, UIKit
            // can take the keyboard focus off it).
            view()
                .child(
                    text_area(answer, l("Type what you hear"))
                        .element_ref(&field)
                        .auto_correct(false)
                        .auto_capitalize(AutoCapitalize::None)
                        .submit_behavior(SubmitBehavior::Submit)
                        .return_key_type(ReturnKeyType::Done)
                        .on_submit(move |_: &str| submit())
                        .on_blur(move |_: &()| {
                            // Lost as the marks come (UIKit's focus engine on
                            // an iPad with a keyboard): back, once a check.
                            if untracked(|| checked.get()) && refocus.with(std::mem::take) {
                                field.focus();
                            }
                        })
                        .on_selection_change(move |selection: &Selection| {
                            let moved = placed.with(|placed| *placed != Some(selection.start))
                                || selection.end != selection.start;
                            if moved {
                                edit();
                            }
                        })
                        .text_base()
                        .text_color(move || theme().foreground.opacity(if checked.get() { 0.0 } else { 1.0 }))
                        .caret(move || !checked.get())
                        .style_when(
                            move || checked.get(),
                            |s| {
                                s.absolute()
                                    .inset_0()
                                    .z_index(1)
                                    .bg(AdaptiveColor::TRANSPARENT)
                                    .border_color(AdaptiveColor::TRANSPARENT)
                            },
                        )
                        .auto_focus(true),
                )
                .child(dynamic(move || {
                    let words = result.get()?;
                    Some(untracked(|| marked_answer(&words).into_element()))
                })),
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
        .child(
            view()
                .flex_row()
                .flex_wrap()
                .items_center()
                .gap_4()
                .child(checkbox(l("Auto replay"), auto_replay, move |on| {
                    store().update_settings(|s| s.dictation_auto_replay = on);
                    if on
                        && review.paused.get_untracked()
                        && !untracked(solved)
                        && let Some(index) = pinned.get_untracked()
                    {
                        review.replay_once(index);
                    }
                }))
                .child(checkbox(l("Auto next"), auto_next, move |on| {
                    store().update_settings(|s| s.dictation_auto_next = on);
                })),
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
    view()
        .flex_row()
        .flex_wrap()
        .items_center()
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
        .child(when(move || !correct, || hint(l("Type to fix it: the caret is at the first mistake."))))
}

/// The checked answer over the input, word by word: each in a green or red
/// box, a missing word as a dashed "…" (the sentence stays hidden), an extra
/// one struck through. Presses go through to the input under it.
fn marked_answer(words: &[DictationWord]) -> impl IntoElement {
    let correct = dictation::is_correct(words);
    let entrance = motion().entering(if correct { MotionPreset::FadeInUp } else { MotionPreset::Shake });
    let tone = move || if correct { tokens::success() } else { theme().destructive };
    let caret = words.iter().position(|word| !matches!(word, DictationWord::Matching(_))).map(|at| {
        let after = !matches!(words[at], DictationWord::Missing(_));
        (at, after)
    });
    view()
        .label(tr("Checked answer"))
        .pointer_events(PointerEvents::None)
        .bind_motion(&entrance)
        .flex_row()
        .flex_wrap()
        .items_start()
        // A space between words as the input sets them, so each word stays
        // about where it was typed; a little between lines keeps the boxes
        // of one off the next.
        .gap_x(px(WORD_SPACE))
        .gap_y(px(4.0))
        .min_h(px(72.0))
        .px_3()
        .py_2()
        .rounded(tokens::radius)
        .border_1()
        .border_color(tone)
        .bg(|| theme().card)
        .children(words.iter().enumerate().map(|(index, word)| {
            let chip = match word {
                DictationWord::Matching(expected) => mark(expected.clone(), Mark::Right),
                DictationWord::Different(_, actual) => mark(actual.clone(), Mark::Wrong),
                DictationWord::Missing(_) => mark("…".into(), Mark::Missing),
                DictationWord::Extra(actual) => mark(actual.clone(), Mark::Extra),
            };
            match caret {
                Some((at, after)) if at == index => with_caret(chip, after),
                _ => chip,
            }
        }))
}

/// The input's caret, drawn where it is under the marks: after the first
/// word typed wrong, or before the first missing one.
fn with_caret(chip: AnyElement, after: bool) -> AnyElement {
    let on = signal(true);
    set_interval(std::time::Duration::from_millis(530), move || on.update(|on| *on = !*on));
    let bar = view()
        .absolute()
        .top(px(2.0))
        .bottom(px(2.0))
        .w(px(2.0))
        .rounded_full()
        .bg(|| theme().primary)
        .opacity(move || if on.get() { 1.0_f32 } else { 0.0 });
    let bar = if after { bar.right(px(0.5)) } else { bar.left(px(0.5)) };
    view().child(chip).child(bar).into_element()
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mark {
    Right,
    Wrong,
    Missing,
    Extra,
}

/// About the width of a space at the body size.
const WORD_SPACE: f32 = 4.5;

fn mark(label: String, kind: Mark) -> AnyElement {
    let right = kind == Mark::Right;
    let tone = move || if right { tokens::success() } else { theme().destructive };
    let word = text(label).text_base().text_color(|| theme().foreground);
    let word = if kind == Mark::Extra { word.line_through() } else { word };
    // The box reaches out around the word: up and down without moving it,
    // so the words sit on the lines typed; sideways moving it a little.
    let chip = view()
        .px(px(5.0))
        .mx(px(-2.0))
        .py(px(2.0))
        .my(px(-2.0))
        .rounded(tokens::radius_sm)
        .border_1()
        .border_color(tone)
        .bg(move || tone().opacity(0.08))
        .child(word);
    if kind == Mark::Missing { chip.border_dashed().into_element() } else { chip.into_element() }
}

fn mimic_panel(review: Review) -> impl IntoElement {
    let store = review.store;
    let target = move || review.target().and_then(|index| review.segment(index));
    let goal = move || store.setting(|s| s.mimic_rep_goal);
    let hidden = move || review.blind() && target().is_none_or(|segment| !review.unveiled(&segment.id));
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
