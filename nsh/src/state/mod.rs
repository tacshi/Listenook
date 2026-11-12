//! The app's state and what it keeps on disk.

pub(crate) mod monitor;
pub(crate) mod persist;
pub(crate) mod podcast;
pub(crate) mod secrets;
mod store;
pub(crate) mod sync;

use listenook_core::l10n;
use nsh_core::prelude::*;
pub(crate) use store::{Filter, Place, Store, store};

/// `text` in the interface language, as a binding: it follows the setting.
pub(crate) fn l(text: &'static str) -> impl Fn() -> SharedString + Copy + 'static {
    move || SharedString::from(l10n::tr(store().lang(), text))
}

/// `text` in the interface language, now.
pub(crate) fn tr(text: &'static str) -> SharedString {
    SharedString::from(l10n::tr(store().lang(), text))
}

/// What to tell the user for an error code, in the interface language.
pub(crate) fn error_text(code: &str) -> SharedString {
    l10n::error_message(store().lang(), code).into()
}
