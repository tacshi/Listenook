//! Keeps the window a video fills at the video's shape as it is resized (`windowShape`), as
//! macOS does with a content aspect ratio: the window is subclassed and the rectangle of each
//! resizing step is fitted (`WM_SIZING`).

use std::cell::Cell;

use nsh_platform_windows::{
    Placement,
    windows::{
        Win32::{
            Foundation::{HWND, LPARAM, LRESULT, RECT, TRUE, WPARAM},
            System::Threading::GetCurrentThreadId,
            UI::{
                Input::KeyboardAndMouse::GetActiveWindow,
                Shell::{DefSubclassProc, RemoveWindowSubclass, SetWindowSubclass},
                WindowsAndMessaging::{
                    EnumThreadWindows, GA_ROOT, GetAncestor, GetClientRect, GetWindowRect, IsWindowVisible,
                    WM_NCDESTROY, WM_SIZING, WMSZ_BOTTOM, WMSZ_BOTTOMLEFT, WMSZ_LEFT, WMSZ_RIGHT, WMSZ_TOP,
                    WMSZ_TOPLEFT, WMSZ_TOPRIGHT,
                },
            },
        },
        core::BOOL,
    },
};

/// The subclass that keeps a window's content at its shape.
const SUBCLASS: usize = 0x6d70_7673;

/// What the window's subclass reads, at one address while the window has it.
#[derive(Default)]
struct Shared {
    /// The width-to-height ratio the content keeps, if any.
    ratio: Cell<Option<f64>>,
    /// The window was destroyed, and its subclass with it.
    gone: Cell<bool>,
}

/// The shape a video's window keeps, and the window, once found. Used on the UI thread.
#[derive(Default)]
pub(super) struct WindowShape {
    shared: Box<Shared>,
    window: Option<HWND>,
}

impl WindowShape {
    /// The window keeps `size` (width, height) from now on; `None` lets it take any shape.
    pub(super) fn set(&self, size: Option<(f64, f64)>) {
        let ratio = size.filter(|(width, height)| *width > 0.0 && *height > 0.0).map(|(width, height)| width / height);
        self.shared.ratio.set(ratio);
    }

    /// The view was put at `at`: with a shape to keep, the window it fills keeps it.
    pub(super) fn placed(&mut self, at: &Placement) {
        if self.window.is_some() || self.shared.ratio.get().is_none() {
            return;
        }
        let Some(window) = window_filled_by(at) else { return };
        let data = (&raw const *self.shared) as usize;
        // SAFETY: `shared` outlives the subclass: it is removed in `drop` or when the window goes.
        if unsafe { SetWindowSubclass(window, Some(keep_shape), SUBCLASS, data) }.as_bool() {
            self.window = Some(window);
        }
    }
}

impl Drop for WindowShape {
    fn drop(&mut self) {
        if let Some(window) = self.window.take().filter(|_| !self.shared.gone.get()) {
            // SAFETY: removes the subclass set on this live window, on its thread.
            unsafe {
                let _ = RemoveWindowSubclass(window, Some(keep_shape), SUBCLASS);
            }
        }
    }
}

/// Keeps the content of the window being resized at the ratio in `data` (a `Shared`).
unsafe extern "system" fn keep_shape(
    window: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
    _id: usize,
    data: usize,
) -> LRESULT {
    // SAFETY: `data` is the `Shared` the subclass was set with, alive until it is removed.
    let shared = unsafe { &*(data as *const Shared) };
    // SAFETY: the window's own message, passed on first so its own limits apply.
    let result = unsafe { DefSubclassProc(window, message, wparam, lparam) };
    match message {
        WM_SIZING => {
            if let Some(ratio) = shared.ratio.get() {
                // SAFETY: WM_SIZING's lparam is the window rectangle being dragged to.
                let rect = unsafe { &mut *(lparam.0 as *mut RECT) };
                if let Some((frame, content)) = measure(window) {
                    fit(rect, wparam.0 as u32, ratio, frame, content);
                    return LRESULT(TRUE.0 as isize);
                }
            }
        }
        WM_NCDESTROY => {
            shared.gone.set(true);
            // SAFETY: removes the subclass set on this window.
            unsafe {
                let _ = RemoveWindowSubclass(window, Some(keep_shape), SUBCLASS);
            }
        }
        _ => {}
    }
    result
}

/// How much wider and taller `window` is than its content, and its content's size.
fn measure(window: HWND) -> Option<((i32, i32), (i32, i32))> {
    let (mut outer, mut inner) = (RECT::default(), RECT::default());
    // SAFETY: queries with local out values.
    unsafe { GetWindowRect(window, &mut outer).ok()? };
    // SAFETY: as above.
    unsafe { GetClientRect(window, &mut inner).ok()? };
    let content = (inner.right - inner.left, inner.bottom - inner.top);
    Some((((outer.right - outer.left) - content.0, (outer.bottom - outer.top) - content.1), content))
}

/// Changes `rect`, a window rectangle a drag at `edge` (`WMSZ_*`) takes a window to, so its
/// content (the rectangle less `frame`) is `ratio` wide for each pixel high: a side follows
/// the edge dragged, a corner the side that changed more from the content's size `was`; the
/// edges across from them stay.
fn fit(rect: &mut RECT, edge: u32, ratio: f64, frame: (i32, i32), was: (i32, i32)) {
    let width = ((rect.right - rect.left) - frame.0).max(1) as f64;
    let height = ((rect.bottom - rect.top) - frame.1).max(1) as f64;
    let by_width = match edge {
        WMSZ_LEFT | WMSZ_RIGHT => true,
        WMSZ_TOP | WMSZ_BOTTOM => false,
        _ => (width / was.0.max(1) as f64 - 1.0).abs() >= (height / was.1.max(1) as f64 - 1.0).abs(),
    };
    if by_width {
        let height = (width / ratio).round() as i32 + frame.1;
        match edge {
            WMSZ_TOPLEFT | WMSZ_TOPRIGHT => rect.top = rect.bottom - height,
            _ => rect.bottom = rect.top + height,
        }
    } else {
        let width = (height * ratio).round() as i32 + frame.0;
        match edge {
            WMSZ_LEFT | WMSZ_TOPLEFT | WMSZ_BOTTOMLEFT => rect.left = rect.right - width,
            _ => rect.right = rect.left + width,
        }
    }
}

/// The window of this thread whose content the view at `at` fills: the one a video that keeps
/// its window's shape plays in (nsh does not say which window a component is in). The active
/// one when several do.
fn window_filled_by(at: &Placement) -> Option<HWND> {
    if at.matrix.M31.abs() > 1.0 || at.matrix.M32.abs() > 1.0 {
        return None;
    }
    unsafe extern "system" fn each(window: HWND, data: LPARAM) -> BOOL {
        // SAFETY: `data` is the list below, alive through EnumThreadWindows.
        unsafe { (*(data.0 as *mut Vec<HWND>)).push(window) };
        TRUE
    }
    let mut windows: Vec<HWND> = Vec::new();
    // SAFETY: the callback only adds to `windows`, which outlives the call.
    unsafe {
        let _ = EnumThreadWindows(GetCurrentThreadId(), Some(each), LPARAM((&raw mut windows) as isize));
    }
    windows.retain(|window| {
        let mut inner = RECT::default();
        // SAFETY: plain queries on windows of this thread.
        let shown = unsafe { IsWindowVisible(*window).as_bool() && GetClientRect(*window, &mut inner).is_ok() };
        shown
            && ((inner.right - inner.left) - at.size.0).abs() <= 1
            && ((inner.bottom - inner.top) - at.size.1).abs() <= 1
    });
    // SAFETY: plain queries.
    let active = unsafe { GetAncestor(GetActiveWindow(), GA_ROOT) };
    windows.iter().find(|window| **window == active).or(windows.first()).copied()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rect(left: i32, top: i32, right: i32, bottom: i32) -> RECT {
        RECT { left, top, right, bottom }
    }

    #[test]
    fn a_side_dragged_sets_the_other_side() {
        let mut r = rect(100, 100, 100 + 1600 + 16, 100 + 500 + 8);
        fit(&mut r, WMSZ_RIGHT, 16.0 / 9.0, (16, 8), (1280, 720));
        assert_eq!(r, rect(100, 100, 1716, 100 + 900 + 8));

        let mut r = rect(100, 100, 600, 460);
        fit(&mut r, WMSZ_TOP, 2.0, (0, 0), (600, 300));
        assert_eq!(r, rect(100, 100, 100 + 720, 460));
    }

    #[test]
    fn a_corner_follows_the_side_that_changed_more_keeping_the_edges_across() {
        let mut r = rect(0, 0, 1200, 500);
        fit(&mut r, WMSZ_TOPLEFT, 2.0, (0, 0), (1000, 500));
        assert_eq!(r, rect(0, -100, 1200, 500));

        let mut r = rect(0, 0, 400, 1000);
        fit(&mut r, WMSZ_BOTTOMLEFT, 2.0, (0, 0), (1000, 500));
        assert_eq!(r, rect(-1600, 0, 400, 1000));
    }
}
