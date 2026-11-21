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
        self, Icon, Size, Status, Tone, Variant, badge, chip, composer_dock, hint, icon, icon_text_button, segmented,
        select, text_area, toast, tokens,
    },
};

/// Where Practice's mode is remembered, for the next time it opens.
const LAST_MODE: &str = "reader_practice_mode";

/// The mode Practice opens in: the one used last, else Type answer.
pub(super) fn last_mode(review: Review) -> Practice {
    let saved = review.store.setting(|s| s.extra.get(LAST_MODE).and_then(|v| v.as_str().map(str::to_owned)));
    if saved.as_deref() == Some("mimic") { Practice::Mimic } else { Practice::Dictation }
}

pub(super) fn start(review: Review, practice: Practice) {
    let mode = if practice == Practice::Mimic { "mimic" } else { "dictation" };
    if untracked(|| last_mode(review)) != practice {
        review.store.update_settings(|s| {
            s.extra.insert(LAST_MODE.into(), mode.into());
        });
    }
    let target = untracked(|| review.target()).or(Some(0));
    batch(|| {
        review.practice.set(practice);
        review.side.set(Side::Practice);
    });
    match (practice, target) {
        (Practice::Mimic, Some(index)) => {
            if review.repeating.get_untracked().is_none() {
                review.repeat_from_start(index);
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
    // Practice is a card docked at the bottom of the reader, under the
    // transcript, in either mode.
    dynamic(move || {
        let practice = review.practice.get();
        untracked(|| match practice {
            Practice::Dictation => composer_dock(dictation_panel(review, heading)).into_element(),
            _ => composer_dock(mimic_panel(review, heading)).into_element(),
        })
    })
}

/// How much faster the sentence takes the top row's room than the controls.
const SENTENCE_GROWS: f32 = 1000.0;

/// The card's top row: the mode, the sentence, then the mode's own controls.
/// It wraps on a narrow card, the controls on a line of their own.
fn practice_bar(review: Review, heading: impl Fn() -> SharedString + 'static, controls: View) -> View {
    view()
        .flex_row()
        .flex_wrap()
        .items_center()
        .gap_2()
        .child(segmented(
            vec![(Practice::Dictation, "Type answer"), (Practice::Mimic, "Mimic")],
            move || if review.practice.get() == Practice::Dictation { Practice::Dictation } else { Practice::Mimic },
            move |practice| {
                if untracked(|| review.practice.get()) != practice {
                    start(review, practice);
                }
            },
        ))
        .child(
            text(heading)
                .flex_1()
                .flex_grow(SENTENCE_GROWS)
                .min_w(px(96.0))
                .number_of_lines(1)
                .text_sm()
                .text_color(|| theme().muted_foreground),
        )
        // Growing far less than the sentence: on its line the sentence takes
        // the room; wrapped to a line of their own (a narrow card, a long
        // sentence), the controls still sit at the right.
        .child(controls.flex_row().items_center().justify_end().gap_2().flex_grow(1.0))
}

/// The input's opacity over the marks: none on a Mac (AppKit takes clicks
/// whatever a view's opacity), elsewhere just over UIKit's 1% floor for
/// taking touches, where its text hardly shows.
fn hidden_input() -> f32 {
    if cfg!(target_os = "macos") { 0.0 } else { 0.011 }
}
/// How long after a check the input's caret moves are its own settling,
/// not the user's: far less than anyone takes to press or type again.
const MARKS_SETTLE: std::time::Duration = std::time::Duration::from_millis(250);
/// How long after the card opens a lost focus is the platform's, not the
/// user's: the input takes it back.
const OPEN_SETTLE: std::time::Duration = std::time::Duration::from_secs(1);
/// How long a correct answer stays up before the next sentence comes.
const AUTO_NEXT_AFTER: std::time::Duration = std::time::Duration::from_millis(1500);
/// Wrong checks of one sentence before a hint is offered and it plays
/// slower.
const MISSES_TO_HELP: u32 = 2;
/// How much slower a sentence plays once it was missed that often, and the
/// slowest it goes.
const SLOWER: f32 = 0.75;
const SLOWEST: f32 = 0.5;
/// How long after the sentence ends, or after the last key typed, it plays
/// again.
const REPLAY_AFTER: std::time::Duration = std::time::Duration::from_millis(1500);

/// Type answer this time round: sentences checked, those right at the first
/// check, and the words missed at a first check (as the transcript has them).
#[derive(Clone, Default, PartialEq)]
struct Tally {
    checked: u32,
    first_try: u32,
    missed: Vec<String>,
}

impl Tally {
    fn summary(&self) -> SharedString {
        format!("{} {}/{}", tr("Right at the first try:"), self.first_try, self.checked).into()
    }
}

fn dictation_panel(review: Review, heading: impl Fn() -> SharedString + 'static) -> impl IntoElement {
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
    // Missed twice, a sentence plays slower (the rate before, and the slower
    // one) and a hint is offered, its first letters then the word.
    let misses = signal(0_u32);
    let hinted = signal(0_u8);
    // Whether this sentence was checked yet (its first check is the one
    // remembered), this time round's tally, going through only the sentences
    // to review, and the end reached.
    let tried = signal(false);
    let tally = signal(Tally::default());
    let only_missed = signal(false);
    let finished = signal(false);
    let slowed = signal(None::<(f32, f32)>);
    // Leaving: the count in a toast, and the speed as it was. The panel's
    // signals are gone by the time it is cleaned up, so what that needs is
    // kept outside them.
    let kept = std::rc::Rc::new(std::cell::RefCell::new((Tally::default(), None::<(f32, f32)>)));
    effect({
        let kept = kept.clone();
        move || *kept.borrow_mut() = (tally.get(), slowed.get())
    });
    cleanup(move || {
        let (tally, slowed) = kept.take();
        if let Some((before, slower)) = slowed
            && review.rate.try_get() == Some(slower)
        {
            review.rate.try_set(before);
        }
        if tally.checked > 0 {
            toast(Tone::Info, tally.summary());
        }
    });
    let unslow = move || {
        if let Some((before, slower)) = slowed.get_untracked() {
            slowed.set(None);
            // Unless the speed was changed by hand meanwhile.
            if review.rate.get_untracked() == slower {
                review.rate.set(before);
            }
        }
    };
    let begin = move |index: usize| {
        unslow();
        batch(|| {
            pinned.set(Some(index));
            answer.set(String::new());
            result.set(None);
            review.revealed.set(None);
            misses.set(0);
            hinted.set(0);
            tried.set(false);
            finished.set(false);
        });
    };
    effect(move || {
        let live = review.target();
        untracked(|| {
            let untouched = answer.with(|a| a.trim().is_empty()) && result.with(Option::is_none);
            let replaying = review.stop_at.get().is_some();
            if untouched && !replaying && live != pinned.get() {
                pinned.set(live);
                finished.set(false);
                tried.set(false);
            }
        });
    });
    let solved = move || result.with(|r| r.as_ref().is_some_and(|words| dictation::is_correct(words)));
    // Its tasks end with the panel (as the replay's below do).
    let advance = stored(None::<Spawned<()>>);
    let field = element_ref();
    let next = move || {
        if let Some(task) = advance.replace(None) {
            task.cancel();
        }
        let after = pinned.get_untracked();
        let next = if only_missed.get_untracked() {
            review.next_to_review(after)
        } else {
            review.next_kept(after.map_or(0, |index| index + 1))
        };
        match next {
            Some(next) => {
                begin(next);
                review.replay_once(next);
            }
            // The end, or none left to review: what this time round came to.
            None => {
                unslow();
                batch(|| {
                    answer.set(String::new());
                    result.set(None);
                    finished.set(true);
                });
                field.blur();
            }
        }
    };
    // From the end: through the sentences to review, or the recording again.
    let restart = move |missed: bool| {
        only_missed.set(missed);
        let at = if missed { review.next_to_review(None) } else { review.next_kept(0) };
        if let Some(at) = at {
            begin(at);
            review.replay_once(at);
            field.focus();
        }
    };
    let toggle_missed = move || {
        let on = !only_missed.get_untracked();
        only_missed.set(on);
        let here = pinned.get_untracked();
        let due = here.and_then(|index| untracked(|| review.segment(index))).is_some_and(|s| s.to_review);
        if on
            && !due
            && let Some(at) = review.next_to_review(here)
        {
            begin(at);
            review.replay_once(at);
        }
    };
    // Until it is answered, the sentence plays again a moment after each
    // time it ends; typing holds that off until a pause in it.
    let again_at = stored(None::<Spawned<()>>);
    let again_later = move || {
        let at = pinned.get_untracked();
        if let Some(task) = again_at.replace(None) {
            task.cancel();
        }
        again_at.replace(Some(spawn(async move {
            timer(REPLAY_AFTER).await;
            again_at.replace(None);
            if let Some(at) = at
                && review.paused.get_untracked()
                && pinned.get_untracked() == Some(at)
                && !untracked(solved)
            {
                review.replay_once(at);
            }
        })));
    };
    let ends_seen = stored(untracked(|| review.ended.get()));
    effect(move || {
        let ended = review.ended.get();
        if ends_seen.replace(ended) == ended {
            return;
        }
        untracked(|| {
            if review.current.get() == pinned.get() && !solved() {
                again_later();
            }
        });
    });
    effect(move || {
        answer.with(|_| ());
        // Typing pushes a replay due back, to a pause in it.
        if again_at.with(|task| task.is_some()) {
            untracked(again_later);
        }
    });
    // The answer as checked, and the caret put after the check: typing or
    // moving the caret takes the marks off.
    let checked_text = stored(String::new());
    let placed = stored(None::<(u32, u32)>);
    // When the marks came: the input's own caret moves just after (taking
    // a new text, then the placed selection) are not the user's.
    let marked_at = stored(None::<std::time::Instant>);
    let refocus = stored(false);
    // When the card opened: the input's focus lost just after (UIKit's
    // focus engine on an iPad with a keyboard, as the card comes) goes back.
    let opened_at = stored(Some(std::time::Instant::now()));
    let check = move || {
        let (Some(segment), true) = (untracked(target), untracked(supported)) else {
            return;
        };
        let mut typed = answer.get_untracked();
        if typed.trim().is_empty() {
            return;
        }
        store().activity.touch();
        let words = dictation::compare(&segment.text, &typed);
        let correct = dictation::is_correct(&words);
        // A sentence's first check is remembered: wrong, it is to review;
        // right, it is done with (as it is when reviewed).
        if !tried.get_untracked() {
            tried.set(true);
            review.set_to_review(&segment.id, !correct);
            let missed = dictation::missed_words(&words);
            tally.update(|tally| {
                tally.checked += 1;
                if correct {
                    tally.first_try += 1;
                }
                for word in missed {
                    if !tally.missed.iter().any(|seen| seen.eq_ignore_ascii_case(&word)) {
                        tally.missed.push(word);
                    }
                }
            });
        }
        // Wrong, it plays again at once; right, the next one comes.
        let again = !correct;
        if correct {
            unslow();
        } else {
            misses.update(|misses| *misses += 1);
        }
        hinted.set(0);
        let before = review.rate.get_untracked();
        let slower = ((before * SLOWER * 20.0).round() / 20.0).max(SLOWEST);
        if again && misses.get_untracked() >= MISSES_TO_HELP && slowed.get_untracked().is_none() && slower < before {
            slowed.set(Some((before, slower)));
            review.rate.set(slower);
        }
        if let Some(task) = again_at.replace(None) {
            task.cancel();
        }
        // The first word typed wrong comes selected, so typing replaces it;
        // a missing one gets a space of its own with the caret in it, so
        // typing the word alone puts it between its neighbours.
        let mut fix = dictation::first_fix(&typed, &words).unwrap_or(typed.len()..typed.len());
        let roomy = !correct && fix.is_empty();
        if roomy {
            let (text, caret) = dictation::room_for_missing(&typed, fix.start);
            typed = text;
            fix = caret..caret;
        }
        let utf16 = |at: usize| typed[..at].encode_utf16().count() as u32;
        let (from, to) = (utf16(fix.start), utf16(fix.end));
        let id = segment.id.clone();
        let mark = move |typed: String, words: Vec<DictationWord>| {
            checked_text.with(|text| *text = typed);
            placed.with(|placed| *placed = Some((from, to)));
            marked_at.with(|at| *at = Some(std::time::Instant::now()));
            refocus.with(|once| *once = true);
            batch(|| {
                if !again {
                    review.paused.set(true);
                }
                if correct {
                    review.answered.update(|answered| {
                        answered.insert(id);
                    });
                }
                result.set(Some(words));
            });
            field.focus();
            field.set_selection(from, to);
        };
        if roomy {
            // The space goes in first: the input takes the new text (moving
            // its caret, which would take marks off) before the marks come.
            answer.set(typed.clone());
            spawn(async move {
                timer(std::time::Duration::ZERO).await;
                if answer.with_untracked(|now| *now == typed) {
                    mark(typed, words);
                }
            });
        } else {
            mark(typed, words);
        }
        if again && let Some(index) = pinned.get_untracked() {
            review.replay_once(index);
        }
        if correct {
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
    // Right, return does nothing: the next sentence comes by itself. iPadOS
    // can repeat the return that checked it (seen 0.6 s on), and that
    // would skip the marks.
    let submit = move || {
        if untracked(solved) {
            return;
        }
        if untracked(|| checked.get()) {
            edit();
        } else {
            check();
        }
    };
    let replay = move || {
        if let Some(index) = pinned.get_untracked() {
            review.replay_once(index);
        }
    };
    // Space types a space: this plays the sentence again from the box.
    on_key_with("mod+r", KeyOptions { when: nsh_core::keymap::When::Always, ..KeyOptions::default() }, move |_| {
        replay();
    });
    on_key_with("mod+enter", KeyOptions { when: nsh_core::keymap::When::Always, ..KeyOptions::default() }, move |_| {
        check()
    });
    view()
        .flex_1()
        .min_h(px(0.0))
        .gap_2()
        .child(practice_bar(
            review,
            // With a tally, the sentence's time gives way to it, so it fits.
            // At the end the summary below says it all.
            move || -> SharedString {
                if finished.get() {
                    return SharedString::default();
                }
                let (first_try, checked) = tally.with(|tally| (tally.first_try, tally.checked));
                match pinned.get() {
                    Some(index) if checked > 0 => {
                        format!("{} {} · {first_try}/{checked} {}", tr("Sentence"), index + 1, tr("first try")).into()
                    }
                    _ => heading(),
                }
            },
            // A sentence's controls, gone at the end: the summary has its own.
            view().child(when(
                move || !finished.get(),
                move || {
                    view()
                        .flex_row()
                        .items_center()
                        .gap_2()
                        .child(when(
                            move || review.left_to_review() > 0,
                            move || {
                                chip(
                                    move || -> SharedString {
                                        format!("{} {}", tr("Missed"), review.left_to_review()).into()
                                    },
                                    move || only_missed.get(),
                                    toggle_missed,
                                )
                            },
                        ))
                        .child(
                            // The glyph says it is a button; the key cap beside it,
                            // how to press it without leaving the answer.
                            when(
                                || !crate::platform::is_phone(),
                                move || ui::shortcut_button(Icon::Refresh, tr("Replay"), "mod+r", replay),
                            )
                            .otherwise(move || ui::icon_button(Icon::Refresh, tr("Replay"), Size::Sm, replay)),
                        )
                        .child(
                            icon_text_button(Variant::Primary, Size::Sm, Icon::Check, l("Check"))
                                .disabled(move || !supported() || answer.with(|a| a.trim().is_empty()))
                                .on_press(check),
                        )
                        .child(icon_text_button(Variant::Ghost, Size::Sm, Icon::SkipForward, l("Next")).on_press(next))
                },
            )),
        ))
        .child(
            // One input throughout, keeping its focus and caret: always laid
            // over the box, last, so the marks come and go under it without
            // moving it (moved among its siblings, the platform takes the
            // keyboard focus off it). Checked, it goes see-through.
            view()
                .flex_1()
                .min_h(px(0.0))
                .child(dynamic(move || {
                    let words = result.get()?;
                    Some(untracked(|| marked_answer(&words).into_element()))
                }))
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
                            // an iPad with a keyboard): back, once a check,
                            // and once as the card opens.
                            let opening = opened_at.with(Option::take).is_some_and(|at| at.elapsed() < OPEN_SETTLE);
                            if opening || (untracked(|| checked.get()) && refocus.with(std::mem::take)) {
                                field.focus();
                            }
                        })
                        .on_selection_change(move |selection: &Selection| {
                            let moved = placed.with(|placed| *placed != Some((selection.start, selection.end)));
                            let settling = marked_at.with(|at| at.is_some_and(|at| at.elapsed() < MARKS_SETTLE));
                            if moved && !settling {
                                edit();
                            }
                        })
                        .absolute()
                        .inset_0()
                        .text_2xl()
                        .selection_color(|| color(theme().primary))
                        // Checked, nothing of it shows over the marks: not
                        // its text, caret, focus ring or selection (drawn on
                        // the chip instead; AppKit draws a selection at 30%,
                        // whatever its color, and the input's words sit a
                        // little off the marks), yet still taking presses
                        // ([`hidden_input`]).
                        // Hidden at the end too: a native text view draws over
                        // the summary laid on it.
                        .opacity(move || if checked.get() || finished.get() { hidden_input() } else { 1.0 })
                        .auto_focus(true),
                )
                // At the end, what this time round came to, over the box.
                .child(when(
                    move || finished.get(),
                    move || the_end(review, tally, only_missed.get_untracked(), restart),
                )),
        )
        .child(when(move || !supported(), || hint(l("Word checking supports English only."))))
        .child(dynamic(move || {
            let Some(words) = result.get() else {
                return view().into_element();
            };
            untracked(|| verdict(&words).into_element())
        }))
        .child(dynamic(move || {
            let words = result.get()?;
            if dictation::is_correct(&words) || misses.get() < MISSES_TO_HELP {
                return None;
            }
            let first = words.iter().find(|word| !matches!(word, DictationWord::Matching(_))).cloned()?;
            Some(untracked(|| help(first, hinted, slowed).into_element()))
        }))
}

/// The end of the recording, or of the sentences to review: how many were
/// right at the first try, the words to listen for, and where to go on.
fn the_end(review: Review, tally: Signal<Tally>, missed_only: bool, restart: impl Fn(bool) + Copy + 'static) -> View {
    let tally = tally.get_untracked();
    let listen_for = (!tally.missed.is_empty()).then(|| {
        format!("{} {}", tr("Listen for:"), tally.missed.iter().take(12).cloned().collect::<Vec<_>>().join(", "))
    });
    view()
        .absolute()
        .inset_0()
        .p_4()
        .gap_3()
        .justify_center()
        .rounded(tokens::radius)
        .border_1()
        .border_color(|| theme().border)
        .bg(|| theme().card)
        .bind_motion(&motion().entering(MotionPreset::FadeInUp))
        .child(
            text(if missed_only { tr("That's all to review.") } else { tr("That's the end.") })
                .text_lg()
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(|| theme().foreground),
        )
        .children((tally.checked > 0).then(|| text(tally.summary()).text_base().text_color(|| theme().foreground)))
        .children(listen_for.map(hint))
        .child(
            view()
                .flex_row()
                .flex_wrap()
                .gap_2()
                .child(when(
                    move || review.left_to_review() > 0,
                    move || {
                        icon_text_button(Variant::Primary, Size::Sm, Icon::Repeat, move || -> SharedString {
                            format!("{} ({})", tr("Review missed"), review.left_to_review()).into()
                        })
                        .on_press(move || restart(true))
                    },
                ))
                .child(
                    icon_text_button(Variant::Outline, Size::Sm, Icon::SkipBack, l("Start over"))
                        .on_press(move || restart(false)),
                ),
        )
}

/// Help once a sentence was missed twice: a hint for its first mistake (the
/// first letters, then the word; an extra word is named) and the slower
/// speed it plays at.
fn help(first: DictationWord, hinted: Signal<u8>, slowed: Signal<Option<(f32, f32)>>) -> impl IntoElement {
    let said = move || -> SharedString {
        match &first {
            DictationWord::Different(word, _) | DictationWord::Missing(word) => {
                format!("{} {}", tr("Hint:"), dictation::hint(word, hinted.get() >= 2)).into()
            }
            DictationWord::Extra(word) | DictationWord::Matching(word) => {
                format!("{} “{word}”", tr("Not said:")).into()
            }
        }
    };
    view()
        .flex_row()
        .flex_wrap()
        .items_center()
        .gap_2()
        .child(when(
            move || hinted.get() == 0,
            move || icon_text_button(Variant::Outline, Size::Sm, Icon::Info, l("Hint")).on_press(move || hinted.set(1)),
        ))
        .child(when(
            move || hinted.get() >= 1,
            move || text(said.clone()).text_sm().font_weight(FontWeight::MEDIUM).text_color(|| theme().foreground),
        ))
        .child(when(
            move || hinted.get() == 1,
            move || ui::button(Variant::Ghost, Size::Sm, l("Show word")).on_press(move || hinted.set(2)),
        ))
        .child(when(
            move || slowed.get().is_some(),
            move || {
                hint(move || -> SharedString {
                    let slower = slowed.get().map_or(1.0, |(_, slower)| slower);
                    format!("{} {}×", tr("Playing slower:"), slower).into()
                })
            },
        ))
}

fn verdict(words: &[DictationWord]) -> impl IntoElement {
    let correct = dictation::is_correct(words);
    let first = words.iter().find(|word| !matches!(word, DictationWord::Matching(_)));
    let missing = matches!(first, Some(DictationWord::Missing(_)));
    let near = matches!(first, Some(DictationWord::Different(expected, typed)) if dictation::is_near(expected, typed));
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
        .child(when(
            move || !correct,
            move || {
                hint(if missing {
                    l("Type the missing word where the caret is.")
                } else if near {
                    l("Close: check the spelling, and type to replace it.")
                } else {
                    l("Type to replace the first mistake.")
                })
            },
        ))
}

/// The checked answer over the input, word by word: each in a green or red
/// box, a missing word as a dashed "…" (the sentence stays hidden), an extra
/// one struck through. Presses go through to the input under it.
fn marked_answer(words: &[DictationWord]) -> impl IntoElement {
    let correct = dictation::is_correct(words);
    let entrance = motion().entering(if correct { MotionPreset::FadeInUp } else { MotionPreset::Shake });
    let tone = move || if correct { tokens::success() } else { theme().destructive };
    // The first mistake: a word typed wrong shows selected (as the input
    // has it), a missing one the caret before it.
    let first = words.iter().position(|word| !matches!(word, DictationWord::Matching(_)));
    view()
        .label(tr("Checked answer"))
        .pointer_events(PointerEvents::None)
        .bind_motion(&entrance)
        .flex_row()
        .flex_wrap()
        .items_start()
        // A space between words as the input sets them, and the input's own
        // lines, so each word stays where it was typed.
        .gap_x(px(WORD_SPACE))
        .flex_1()
        .px_3()
        .py_2()
        .rounded(tokens::radius)
        .border_1()
        .border_color(tone)
        .bg(|| theme().card)
        .children(words.iter().enumerate().map(|(index, word)| {
            let selected = first == Some(index);
            match word {
                DictationWord::Matching(expected) => mark(expected.clone(), Mark::Right, false),
                DictationWord::Different(expected, actual) if dictation::is_near(expected, actual) => {
                    mark(actual.clone(), Mark::Near, selected)
                }
                DictationWord::Different(_, actual) => mark(actual.clone(), Mark::Wrong, selected),
                DictationWord::Missing(_) if selected => with_caret(mark("…".into(), Mark::Missing, false)),
                DictationWord::Missing(_) => mark("…".into(), Mark::Missing, false),
                DictationWord::Extra(actual) => mark(actual.clone(), Mark::Extra, selected),
            }
        }))
}

/// The input's caret, drawn where it is under the marks: before the first
/// missing word.
fn with_caret(chip: AnyElement) -> AnyElement {
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
    view().child(chip).child(bar.left(px(0.5))).into_element()
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mark {
    Right,
    /// Typed a letter off (amber): spelling, not hearing.
    Near,
    Wrong,
    Missing,
    Extra,
}

/// About the width of a space at the answer's size (24pt).
const WORD_SPACE: f32 = 6.5;
/// The answer's line (24pt text on 32pt lines), and the box of a marked
/// word inside it: a little shorter, so the boxes of two lines keep apart.
const ANSWER_LINE: f32 = 32.0;
const MARK_LINE: f32 = 28.0;
/// How far a mark's box reaches past its word on each side: under half
/// a space, so two boxes keep apart.
const MARK_REACH: f32 = 2.5;

fn mark(label: String, kind: Mark, selected: bool) -> AnyElement {
    let tone = move || match kind {
        Mark::Right => tokens::success(),
        Mark::Near => tokens::warning(),
        _ => theme().destructive,
    };
    let word = text(label)
        .text_2xl()
        .line_height(nsh_core::LineHeight::Points(px(MARK_LINE)))
        .text_color(|| theme().foreground);
    let word = if kind == Mark::Extra { word.line_through() } else { word };
    // The box sits in the middle of the input's line and reaches out
    // sideways into the spaces, so each word stays where it was typed.
    let chip = view()
        .px(px(MARK_REACH))
        .mx(px(-MARK_REACH))
        .my(px((ANSWER_LINE - MARK_LINE) / 2.0))
        .rounded(tokens::radius_sm)
        .border_1()
        .border_color(tone)
        .bg(move || if selected { theme().primary.opacity(0.35) } else { tone().opacity(0.08) })
        .child(word);
    if kind == Mark::Missing { chip.border_dashed().into_element() } else { chip.into_element() }
}

fn mimic_panel(review: Review, heading: impl Fn() -> SharedString + 'static) -> impl IntoElement {
    let store = review.store;
    let target = move || review.target().and_then(|index| review.segment(index));
    let goal = move || store.setting(|s| s.mimic_rep_goal);
    let hidden = move || review.blind() && target().is_none_or(|segment| !review.unveiled(&segment.id));
    let reps = select(
        "Target reps",
        [1, 2, 3, 5, 10, 20, 30].iter().map(|n| (n.to_string().into(), format!("{n}×").into())).collect(),
        move || SharedString::from(goal().to_string()),
        move |value| {
            let goal = value.parse().unwrap_or(3);
            store.update_settings(|s| s.mimic_rep_goal = goal);
            review.reps.update(|reps| *reps = (*reps).min(goal));
        },
    );
    let pause = select(
        "Pause",
        [0, 1, 2, 3, 5, 10]
            .iter()
            .map(|n| (n.to_string().into(), if *n == 0 { tr("Auto") } else { format!("{n} s").into() }))
            .collect(),
        move || SharedString::from(store.setting(|s| s.mimic_pause_seconds).to_string()),
        move |value| store.update_settings(|s| s.mimic_pause_seconds = value.parse().unwrap_or(0)),
    );
    view()
        .flex_1()
        .min_h(px(0.0))
        .gap_2()
        .child(practice_bar(
            review,
            heading,
            view()
                .child(hint(l("Reps")))
                .child(reps.w(px(MIMIC_SELECT)))
                .child(hint(l("Pause")))
                .child(pause.w(px(MIMIC_SELECT))),
        ))
        .child(
            scroll().flex_1().child(
                view()
                    .gap_3()
                    .py_2()
                    .child(ui::veil(hidden, move || {
                        view()
                            .gap_2()
                            .child(
                                text(move || {
                                    target().map(|segment| SharedString::from(segment.text)).unwrap_or_default()
                                })
                                .text_2xl()
                                .text_color(|| theme().foreground),
                            )
                            .child(when(
                                move || target().is_some_and(|segment| segment.has_translation()),
                                move || {
                                    text(move || {
                                        target().and_then(|s| s.translated_text).map(SharedString::from).unwrap_or_default()
                                    })
                                    .text_base()
                                    .text_color(|| theme().muted_foreground)
                                },
                            ))
                    }))
                    .child(
                        view()
                            .flex_row()
                            .flex_wrap()
                            .items_center()
                            .gap_2()
                            .child(mimic_controls(review))
                            .child(badge(
                                move || -> SharedString {
                                    format!("{} {}/{}", tr("Reps"), review.reps.get(), goal()).into()
                                },
                                move || if review.waiting.get() { Status::Active } else { Status::Neutral },
                            ))
                            .child(when(move || review.waiting.get(), || hint(l("Your turn…"))))
                            .child(when(
                                move || !review.waiting.get(),
                                || hint(l("Each sentence plays, then waits for you to say it. Press a sentence to practice it.")),
                            )),
                    ),
            ),
        )
}

/// The previous sentence, play or pause, and the next, in the card itself:
/// no trip to the transport under it or to the transcript.
fn mimic_controls(review: Review) -> View {
    let active = move || !review.paused.get() || review.waiting.get();
    view()
        .flex_row()
        .items_center()
        .gap_1()
        .child(ui::icon_button(Icon::SkipBack, tr("Previous sentence"), Size::Sm, move || review.step(-1)))
        .child(
            ui::toggle_icon_button(
                move || if active() { Icon::Pause } else { Icon::Play },
                move || if active() { tr("Pause playback") } else { tr("Play") },
                Variant::Ghost,
                Size::Sm,
            )
            .on_press(move || review.toggle_play()),
        )
        .child(ui::icon_button(Icon::SkipForward, tr("Next sentence"), Size::Sm, move || review.step(1)))
}

/// A Reps or Pause choice in the card's top row: wide enough for "30×".
const MIMIC_SELECT: f32 = 88.0;
