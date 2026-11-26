//! The words the app shows, in the language the person chose: the state above the widgets
//! tells it which ([`set_lang`]), and everything that shows a word reads it from here.

use listenook_core::l10n::{self, Lang};
use nsh_core::prelude::*;

#[derive(Clone, Copy, Default)]
struct Shown(Lang);

/// The language the app shows its words in, followed reactively.
pub(crate) fn lang() -> Lang {
    global::<Shown>().get().0
}

pub(crate) fn set_lang(lang: Lang) {
    if global::<Shown>().get_untracked().0 != lang {
        global::<Shown>().set(Shown(lang));
    }
}

pub(crate) fn l(text: &'static str) -> impl Fn() -> SharedString + Copy + 'static {
    move || SharedString::from(l10n::tr(lang(), text))
}

pub(crate) fn tr(text: &'static str) -> SharedString {
    SharedString::from(l10n::tr(lang(), text))
}

pub(crate) fn error_text(code: &str) -> SharedString {
    l10n::error_message(lang(), code).into()
}
