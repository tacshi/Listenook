//! What the app holds while it runs: the library and its settings in the [`Store`], and the
//! states of the features beside it, each made once as the app starts ([`install`]) and
//! reached from anywhere after ([`installed`]).

pub(crate) mod activity;
pub(crate) mod monitor;
pub(crate) mod podcast;
pub(crate) mod sleep;
mod store;

use nsh_core::prelude::*;
pub(crate) use store::{Action, AiSetup, Filter, Place, SettingsTab, Shelf, Store, store};

struct Installed<T>(Option<T>);

impl<T> Default for Installed<T> {
    fn default() -> Self {
        Self(None)
    }
}

impl<T: Copy> Clone for Installed<T> {
    fn clone(&self) -> Self {
        Self(self.0)
    }
}

/// Keeps `state` for the rest of the app's run.
pub(crate) fn install<T: Copy + 'static>(state: T) {
    global::<Installed<T>>().set(Installed(Some(state)));
}

/// The state of this kind made as the app started.
pub(crate) fn installed<T: Copy + 'static>() -> T {
    global::<Installed<T>>().get_untracked().0.expect("the root component installs the app's state")
}
