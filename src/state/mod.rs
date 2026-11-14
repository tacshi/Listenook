pub(crate) mod monitor;
pub(crate) mod persist;
pub(crate) mod podcast;
pub(crate) mod secrets;
mod store;
pub(crate) mod sync;

use listenook_core::l10n;
use nsh_core::prelude::*;
pub(crate) use store::{Filter, Place, Store, store};

pub(crate) fn l(text: &'static str) -> impl Fn() -> SharedString + Copy + 'static {
    move || SharedString::from(l10n::tr(store().lang(), text))
}

pub(crate) fn tr(text: &'static str) -> SharedString {
    SharedString::from(l10n::tr(store().lang(), text))
}

pub(crate) fn error_text(code: &str) -> SharedString {
    l10n::error_message(store().lang(), code).into()
}
