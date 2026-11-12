//! The system's media controls, as the app sees them: it says what is playing, and hears what the system asks. Whoever
//! plays claims the controls; the last to claim them has them, and gives
//! them back when it goes.

use std::{cell::RefCell, rc::Rc};

/// What the system asks of the app.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum Command {
    Play,
    Pause,
    Toggle,
    Next,
    Previous,
    /// To a position, in milliseconds.
    Seek(i64),
}

/// What is playing, for the system to show.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Now {
    pub(crate) title: String,
    pub(crate) artist: String,
    pub(crate) position_ms: i64,
    pub(crate) duration_ms: i64,
    pub(crate) playing: bool,
    pub(crate) rate: f32,
}

type Handler = Rc<dyn Fn(Command)>;

thread_local! {
    /// Who has the controls, the last to claim them last.
    static CLAIMS: RefCell<Vec<(u32, Handler)>> = const { RefCell::new(Vec::new()) };
    static NEXT: std::cell::Cell<u32> = const { std::cell::Cell::new(1) };
}

/// A claim on the media controls: dropped, they go back to whoever had
/// them before.
pub(crate) struct Claim(u32);

impl Claim {
    /// Says what the claimant is playing. Ignored while someone else has
    /// claimed the controls since.
    pub(crate) fn publish(&self, now: Option<Now>) {
        if CLAIMS.with(|claims| claims.borrow().last().is_some_and(|(id, _)| *id == self.0)) {
            show(now);
        }
    }
}

impl Drop for Claim {
    fn drop(&mut self) {
        let was_top = CLAIMS.with(|claims| {
            let mut claims = claims.borrow_mut();
            let top = claims.last().is_some_and(|(id, _)| *id == self.0);
            claims.retain(|(id, _)| *id != self.0);
            top
        });
        if was_top {
            show(None);
        }
    }
}

/// Claims the media controls: `handle` hears play, pause, next, previous
/// and seek until the claim is dropped or someone else claims them.
pub(crate) fn claim(handle: impl Fn(Command) + 'static) -> Claim {
    let id = NEXT.with(|next| next.replace(next.get() + 1));
    CLAIMS.with(|claims| claims.borrow_mut().push((id, Rc::new(handle))));
    Claim(id)
}

/// Asks whoever has the controls to do `command`: what a key that works
/// from anywhere presses.
pub(crate) fn press(command: Command) {
    let handler = CLAIMS.with(|claims| claims.borrow().last().map(|(_, handler)| handler.clone()));
    if let Some(handler) = handler {
        handler(command);
    }
}

fn show(now: Option<Now>) {
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    super::apple::now_playing(now);
    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    let _ = now;
}

/// Hands what the system asked since the last call to who should hear it.
/// Call it regularly on the engine thread.
pub(crate) fn pump() {
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    for command in super::apple::take() {
        let handler = CLAIMS.with(|claims| claims.borrow().last().map(|(_, handler)| handler.clone()));
        if let Some(handler) = handler {
            handler(command);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_last_claim_has_the_controls_and_gives_them_back() {
        let heard = Rc::new(RefCell::new(Vec::new()));
        let top = |heard: &Rc<RefCell<Vec<&'static str>>>| {
            let handler = CLAIMS.with(|claims| claims.borrow().last().map(|(_, handler)| handler.clone()));
            if let Some(handler) = handler {
                handler(Command::Toggle);
            }
            heard.borrow().last().copied()
        };
        let (a, b) = (heard.clone(), heard.clone());
        let podcast = claim(move |_| a.borrow_mut().push("podcast"));
        assert_eq!(top(&heard), Some("podcast"));
        let reader = claim(move |_| b.borrow_mut().push("reader"));
        assert_eq!(top(&heard), Some("reader"));
        drop(reader);
        assert_eq!(top(&heard), Some("podcast"));
        drop(podcast);
        assert!(CLAIMS.with(|claims| claims.borrow().is_empty()));
    }
}
