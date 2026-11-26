//! Keeps the window a video fills at the video's shape as it is resized (`windowShape`), as
//! macOS does with a content aspect ratio: the window is subclassed and the rectangle of each
//! resizing step is fitted (`WM_SIZING`).
//!
//! nsh does not say which window a component is in: it is the window on the UI thread whose
//! content the view fills and, when several do, the one whose message the frame that placed the
//! view was drawn for (seen with a `WH_GETMESSAGE` hook while the window is looked for).

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
                    CallNextHookEx, EnumThreadWindows, GA_ROOT, GetAncestor, GetClientRect, GetWindowRect, HHOOK,
                    IsWindowVisible, MSG, SetWindowsHookExW, UnhookWindowsHookEx, WH_GETMESSAGE, WM_NCDESTROY,
                    WM_SIZING, WMSZ_BOTTOM, WMSZ_BOTTOMLEFT, WMSZ_LEFT, WMSZ_RIGHT, WMSZ_TOP, WMSZ_TOPLEFT,
                    WMSZ_TOPRIGHT,
                },
            },
        },
        core::BOOL,
    },
};

thread_local! {
    /// The window of the message this thread took from its queue last (`WH_GETMESSAGE`): the one
    /// a frame drawn while it is handled is drawn for.
    static TAKEN: Cell<isize> = const { Cell::new(0) };
}

/// Notes the window of each message this thread takes from its queue.
unsafe extern "system" fn note_taken(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0 {
        // SAFETY: a WH_GETMESSAGE hook's lparam is the message taken.
        let message = unsafe { &*(lparam.0 as *const MSG) };
        TAKEN.with(|taken| taken.set(message.hwnd.0 as isize));
    }
    // SAFETY: passes the message on to the other hooks, as a hook must.
    unsafe { CallNextHookEx(None, code, wparam, lparam) }
}

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
    /// Notes the windows of the messages taken while the window is looked for.
    hook: Option<HHOOK>,
}

impl WindowShape {
    /// The window keeps `size` (width, height) from now on; `None` lets it take any shape.
    pub(super) fn set(&mut self, size: Option<(f64, f64)>) {
        let ratio = size.filter(|(width, height)| *width > 0.0 && *height > 0.0).map(|(width, height)| width / height);
        self.shared.ratio.set(ratio);
        if ratio.is_some() && self.window.is_none() && self.hook.is_none() {
            // SAFETY: a hook of this thread's messages, removed once the window is found or in `drop`.
            self.hook = unsafe { SetWindowsHookExW(WH_GETMESSAGE, Some(note_taken), None, GetCurrentThreadId()) }
                .inspect_err(|why| log::warn!("the video's window may be found wrongly: {why}"))
                .ok();
        }
    }

    /// The view was put at `at`: with a shape to keep, the window it fills keeps it.
    pub(super) fn placed(&mut self, at: &Placement) {
        if self.window.is_some() || self.shared.ratio.get().is_none() {
            return;
        }
        let Some(window) = window_filled_by(at) else { return };
        let data = (&raw const *self.shared) as usize;
        // SAFETY: `shared` outlives the subclass: it is removed in `drop` or when the window goes.
        // Its address tells it from another video's on the same window.
        if unsafe { SetWindowSubclass(window, Some(keep_shape), data, data) }.as_bool() {
            self.window = Some(window);
            self.unhook();
        }
    }

    fn unhook(&mut self) {
        if let Some(hook) = self.hook.take() {
            // SAFETY: the hook set in `set`, on this thread.
            unsafe {
                let _ = UnhookWindowsHookEx(hook);
            }
        }
    }
}

impl Drop for WindowShape {
    fn drop(&mut self) {
        self.unhook();
        if let Some(window) = self.window.take().filter(|_| !self.shared.gone.get()) {
            let id = (&raw const *self.shared) as usize;
            // SAFETY: removes the subclass set on this live window, on its thread.
            unsafe {
                let _ = RemoveWindowSubclass(window, Some(keep_shape), id);
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
    id: usize,
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
                if let Some(frame) = frame(window) {
                    fit(rect, wparam.0 as u32, ratio, frame);
                    return LRESULT(TRUE.0 as isize);
                }
            }
        }
        WM_NCDESTROY => {
            shared.gone.set(true);
            // SAFETY: removes the subclass set on this window.
            unsafe {
                let _ = RemoveWindowSubclass(window, Some(keep_shape), id);
            }
        }
        _ => {}
    }
    result
}

/// How much wider and taller `window` is than its content.
fn frame(window: HWND) -> Option<(i32, i32)> {
    let (mut outer, mut inner) = (RECT::default(), RECT::default());
    // SAFETY: queries with local out values.
    unsafe { GetWindowRect(window, &mut outer).ok()? };
    // SAFETY: as above.
    unsafe { GetClientRect(window, &mut inner).ok()? };
    Some((
        (outer.right - outer.left) - (inner.right - inner.left),
        (outer.bottom - outer.top) - (inner.bottom - inner.top),
    ))
}

/// Changes `rect`, the window rectangle a drag at `edge` (`WMSZ_*`) proposes, so its content
/// (the rectangle less `frame`) is `ratio` wide for each pixel high: a side keeps where it was
/// dragged and sets the other; a corner goes to the size of that shape nearest the one dragged
/// to. The edges across from those dragged stay.
///
/// Only the proposed rectangle counts: Windows proposes one that follows the pointer, so a rule
/// that also looked at the window's size, already fitted, swung between the two at each step.
fn fit(rect: &mut RECT, edge: u32, ratio: f64, frame: (i32, i32)) {
    let width = ((rect.right - rect.left) - frame.0).max(1) as f64;
    let height = ((rect.bottom - rect.top) - frame.1).max(1) as f64;
    let (width, height) = match edge {
        WMSZ_LEFT | WMSZ_RIGHT => (width, width / ratio),
        WMSZ_TOP | WMSZ_BOTTOM => (height * ratio, height),
        _ => {
            let height = (width * ratio + height) / (ratio * ratio + 1.0);
            (height * ratio, height)
        }
    };
    let (width, height) = (width.round() as i32 + frame.0, height.round() as i32 + frame.1);
    match edge {
        WMSZ_LEFT | WMSZ_TOPLEFT | WMSZ_BOTTOMLEFT => rect.left = rect.right - width,
        _ => rect.right = rect.left + width,
    }
    match edge {
        WMSZ_TOP | WMSZ_TOPLEFT | WMSZ_TOPRIGHT => rect.top = rect.bottom - height,
        _ => rect.bottom = rect.top + height,
    }
}

/// The window of this thread whose content the view at `at` fills: the one a video that keeps
/// its window's shape plays in. When several do, the one the frame that placed it was drawn
/// for, else the active one.
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
    let (drawn, active) = unsafe {
        (GetAncestor(HWND(TAKEN.with(Cell::get) as *mut _), GA_ROOT), GetAncestor(GetActiveWindow(), GA_ROOT))
    };
    let found = |wanted: HWND| windows.iter().copied().find(|window| *window == wanted);
    found(drawn).or_else(|| found(active)).or(windows.first().copied())
}

#[cfg(test)]
mod tests {
    use nsh_platform_windows::windows::Win32::UI::WindowsAndMessaging::WMSZ_BOTTOMRIGHT;

    use super::*;

    fn rect(left: i32, top: i32, right: i32, bottom: i32) -> RECT {
        RECT { left, top, right, bottom }
    }

    #[test]
    fn a_side_dragged_sets_the_other_side() {
        let mut r = rect(100, 100, 100 + 1600 + 16, 100 + 500 + 8);
        fit(&mut r, WMSZ_RIGHT, 16.0 / 9.0, (16, 8));
        assert_eq!(r, rect(100, 100, 1716, 100 + 900 + 8));

        let mut r = rect(100, 100, 600, 460);
        fit(&mut r, WMSZ_TOP, 2.0, (0, 0));
        assert_eq!(r, rect(100, 100, 100 + 720, 460));
    }

    #[test]
    fn a_corner_goes_to_the_nearest_size_keeping_the_edges_across() {
        let mut r = rect(0, 0, 1000, 1000);
        fit(&mut r, WMSZ_BOTTOMRIGHT, 2.0, (0, 0));
        assert_eq!(r, rect(0, 0, 1200, 600));

        let mut r = rect(0, 0, 1000, 1000);
        fit(&mut r, WMSZ_TOPLEFT, 2.0, (0, 0));
        assert_eq!(r, rect(-200, 400, 1000, 1000));
    }

    #[test]
    fn a_corner_dragged_along_one_side_resizes_steadily() {
        // Windows keeps proposing the height the drag started at while the pointer moves left.
        let mut last = i32::MAX;
        for width in (1000..=1518).rev().step_by(16) {
            let mut r = rect(0, 0, width, 854);
            fit(&mut r, WMSZ_BOTTOMRIGHT, 16.0 / 9.0, (0, 0));
            let fitted = r.right - r.left;
            assert!(fitted < last, "{fitted} after {last}");
            assert!((f64::from(fitted) / f64::from(r.bottom - r.top) - 16.0 / 9.0).abs() < 0.01);
            last = fitted;
        }
    }
}
