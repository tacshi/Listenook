//! A video's own window, held (`holdWindow`), opens out of sight and shows once a frame of the
//! video is drawn at the video's shape (`windowShape`), or after [`HOLD_MAX`]: it opens showing
//! the video rather than empty, then reshaped. How a window is kept out of sight differs by
//! platform; this is when it shows again on macOS. (GTK draws nothing in a window kept out of
//! sight, see-through or unmapped, so a window on Linux opens as it is.)

#[cfg(target_os = "macos")]
use std::sync::Mutex;
use std::time::Duration;

/// The longest a held window stays out of sight: shown then whatever it shows (a file without a
/// picture, or that does not play).
pub(crate) const HOLD_MAX: Duration = Duration::from_millis(1500);

/// Which window is held, and when it shows. `W` is how the platform shows a window again; each
/// window is told apart by an id of the platform's.
#[cfg(target_os = "macos")]
pub(crate) struct Hold<W> {
    state: Mutex<Held<W>>,
}

#[cfg(target_os = "macos")]
struct Held<W> {
    /// The app asked for the window to be held, and it was not shown since.
    holding: bool,
    /// The window the view is in, kept out of sight until it shows.
    window: Option<(usize, W)>,
    /// The video's width and height.
    shape: Option<(f64, f64)>,
}

#[cfg(target_os = "macos")]
impl<W> Default for Hold<W> {
    fn default() -> Self {
        Hold { state: Mutex::new(Held { holding: false, window: None, shape: None }) }
    }
}

#[cfg(target_os = "macos")]
impl<W> Hold<W> {
    fn state(&self) -> std::sync::MutexGuard<'_, Held<W>> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The app asks for the window the view is in to be held as it opens, until
    /// [`Self::release`] at the latest.
    pub(crate) fn want(&self) {
        self.state().holding = true;
    }

    /// The view is in window `id` now (made into a `W` by `window`). `None`: nothing to do;
    /// `Some(left)`: keep this window out of sight now, and show `left` again, the window held
    /// before, which the view left (nsh may lay a view out in one window before placing it in
    /// another).
    pub(crate) fn catch(&self, id: usize, window: impl FnOnce() -> W) -> Option<Option<W>> {
        let mut state = self.state();
        if !state.holding || state.window.as_ref().is_some_and(|(held, _)| *held == id) {
            return None;
        }
        Some(state.window.replace((id, window())).map(|(_, left)| left))
    }

    /// The video's shape (`None`: not known).
    pub(crate) fn shape(&self, shape: Option<(f64, f64)>) {
        self.state().shape = shape;
    }

    /// A frame was drawn, `size` pixels, showing the video (`pictured`) or not yet: the window to
    /// show, when it shows the video at its shape.
    pub(crate) fn drawn(&self, size: (f64, f64), pictured: bool) -> Option<W> {
        let shaped = self.state().shape.is_some_and(|shape| same_shape(size, shape));
        if pictured && shaped { self.release() } else { None }
    }

    /// Ends the hold: the window to show, held still. When it has waited long enough, or the
    /// view goes.
    pub(crate) fn release(&self) -> Option<W> {
        let mut state = self.state();
        state.holding = false;
        state.window.take().map(|(_, window)| window)
    }
}

#[cfg(target_os = "macos")]
/// Whether `size` has `shape`'s width to height, but for rounding: a window is shaped in whole
/// points, and its title bar and frame are rounded apart.
fn same_shape(size: (f64, f64), shape: (f64, f64)) -> bool {
    let (ratio, wanted) = (size.0 / size.1, shape.0 / shape.1);
    ratio.is_finite() && wanted.is_finite() && wanted > 0.0 && (ratio / wanted - 1.0).abs() < 0.01
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    #[test]
    fn a_held_window_shows_once_the_video_is_drawn_at_its_shape() {
        let hold = Hold::default();
        hold.want();
        assert_eq!(hold.catch(1, || "window"), Some(None));
        assert_eq!(hold.drawn((1920.0, 1200.0), true), None, "no shape known yet");
        hold.shape(Some((3840.0, 2160.0)));
        assert_eq!(hold.drawn((1920.0, 1200.0), true), None, "the window is not at the video's shape yet");
        assert_eq!(hold.drawn((2560.0, 1441.0), false), None, "black, before the video's first frame");
        assert_eq!(hold.drawn((2560.0, 1441.0), true), Some("window"));
        assert_eq!(hold.drawn((2560.0, 1441.0), true), None, "shown once");
        assert_eq!(hold.catch(2, || "another"), None, "the hold is over");
    }

    #[test]
    fn only_a_window_asked_for_is_held() {
        let hold = Hold::default();
        assert_eq!(hold.catch(1, || "window"), None);
        hold.want();
        assert_eq!(hold.catch(1, || "window"), Some(None));
        assert_eq!(hold.catch(1, || "window"), None, "held already");
    }

    #[test]
    fn the_hold_follows_the_view_to_another_window() {
        let hold = Hold::default();
        hold.want();
        assert_eq!(hold.catch(1, || "first"), Some(None));
        assert_eq!(hold.catch(2, || "second"), Some(Some("first")), "the window left shows again");
        assert_eq!(hold.release(), Some("second"));
    }

    #[test]
    fn a_window_shows_when_released_and_after() {
        let hold = Hold::default();
        hold.want();
        assert_eq!(hold.catch(1, || "window"), Some(None));
        assert_eq!(hold.release(), Some("window"));
        assert_eq!(hold.drawn((16.0, 9.0), true), None);
        assert_eq!(hold.catch(2, || "another"), None);
    }
}
