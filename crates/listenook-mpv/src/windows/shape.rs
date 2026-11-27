//! Keeps the window a video fills at the video's shape as it is resized (`windowShape`), as
//! macOS does with a content aspect ratio: the window is subclassed and the rectangle of each
//! resizing step is fitted (`WM_SIZING`).
//!
//! Held (`holdWindow`), the window is also kept out of sight from the moment it shows (cloaked:
//! it is drawn and composed as usual, but not shown) until [`reveal`]: it opens showing the
//! video, at its shape, rather than empty, then reshaped. The view is made before its window
//! shows but placed in it only after, so the window is caught as it shows: the first window of
//! the thread to show while the view looks for one (`WM_SHOWWINDOW`, seen with a
//! `WH_CALLWNDPROC` hook), which its placement confirms.
//!
//! nsh does not say which window a component is in: it is the window on the UI thread whose
//! content the view fills and, when several do, the one whose message the frame that placed the
//! view was drawn for (seen with a `WH_GETMESSAGE` hook while the window is looked for).

use std::{cell::Cell, sync::OnceLock};

use nsh_platform_windows::{
    Placement,
    windows::{
        Win32::{
            Foundation::{FALSE, HWND, LPARAM, LRESULT, RECT, TRUE, WPARAM},
            Graphics::Dwm::{DWMWA_CLOAK, DwmSetWindowAttribute},
            System::Threading::GetCurrentThreadId,
            UI::{
                Input::KeyboardAndMouse::GetActiveWindow,
                Shell::{DefSubclassProc, RemoveWindowSubclass, SetWindowSubclass},
                WindowsAndMessaging::{
                    CWPSTRUCT, CallNextHookEx, EnumThreadWindows, GA_ROOT, GW_OWNER, GWL_EXSTYLE, GetAncestor,
                    GetClientRect, GetWindow, GetWindowLongPtrW, GetWindowRect, HHOOK, IsWindowVisible, MSG,
                    PostMessageW, RegisterWindowMessageW, SetWindowsHookExW, UnhookWindowsHookEx, WH_CALLWNDPROC,
                    WH_GETMESSAGE, WM_NCDESTROY, WM_SHOWWINDOW, WM_SIZING, WMSZ_BOTTOM, WMSZ_BOTTOMLEFT, WMSZ_LEFT,
                    WMSZ_RIGHT, WMSZ_TOP, WMSZ_TOPLEFT, WMSZ_TOPRIGHT, WS_EX_TOOLWINDOW,
                },
            },
        },
        core::{BOOL, w},
    },
};

use crate::hold::HOLD_MAX;

thread_local! {
    /// The window of the message this thread took from its queue last (`WH_GETMESSAGE`): the one
    /// a frame drawn while it is handled is drawn for.
    static TAKEN: Cell<isize> = const { Cell::new(0) };
    /// The window a held view's hook kept out of sight as it showed (0: none yet).
    static CAUGHT: Cell<isize> = const { Cell::new(0) };
}

/// Keeps the first window of this thread to show out of sight, as it shows: a held view's
/// window, before anything of it is seen.
unsafe extern "system" fn catch_shown(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0 {
        // SAFETY: a WH_CALLWNDPROC hook's lparam is the message sent.
        let message = unsafe { &*(lparam.0 as *const CWPSTRUCT) };
        let window = message.hwnd;
        if message.message == WM_SHOWWINDOW && message.wParam.0 != 0 && CAUGHT.with(Cell::get) == 0 {
            // SAFETY: plain queries on a window of this thread.
            let (top, owned, tool) = unsafe {
                (
                    GetAncestor(window, GA_ROOT) == window,
                    GetWindow(window, GW_OWNER).is_ok_and(|owner| !owner.is_invalid()),
                    GetWindowLongPtrW(window, GWL_EXSTYLE) as u32 & WS_EX_TOOLWINDOW.0 != 0,
                )
            };
            if top && !owned && !tool {
                cloak(window, true);
                CAUGHT.with(|caught| caught.set(window.0 as isize));
                // Shown whatever happens, should its view not be placed in it.
                let window = window.0 as isize;
                let _ = std::thread::Builder::new().name("mpv-hold".into()).spawn(move || {
                    std::thread::sleep(HOLD_MAX);
                    cloak(HWND(window as *mut _), false);
                });
            }
        }
    }
    // SAFETY: passes the message on to the other hooks, as a hook must.
    unsafe { CallNextHookEx(None, code, wparam, lparam) }
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
    /// The window is kept out of sight until [`reveal`].
    held: bool,
    /// Catches the window as it shows, while held and not found.
    catch: Option<HHOOK>,
}

impl WindowShape {
    /// The window keeps `size` (width, height) from now on; `None` lets it take any shape.
    pub(super) fn set(&mut self, size: Option<(f64, f64)>) {
        let ratio = size.filter(|(width, height)| *width > 0.0 && *height > 0.0).map(|(width, height)| width / height);
        self.shared.ratio.set(ratio);
        if ratio.is_some() {
            self.look();
        }
    }

    /// The window is kept out of sight from the moment it shows until [`reveal`].
    pub(super) fn hold(&mut self) {
        if self.held || self.window.is_some() {
            return;
        }
        self.held = true;
        self.look();
        CAUGHT.with(|caught| caught.set(0));
        // SAFETY: a hook of this thread's sent messages, removed once the window is found or in
        // `drop`.
        self.catch = unsafe { SetWindowsHookExW(WH_CALLWNDPROC, Some(catch_shown), None, GetCurrentThreadId()) }
            .inspect_err(|why| log::warn!("the video's window may show before its picture: {why}"))
            .ok();
    }

    fn look(&mut self) {
        if self.window.is_none() && self.hook.is_none() {
            // SAFETY: a hook of this thread's messages, removed once the window is found or in `drop`.
            self.hook = unsafe { SetWindowsHookExW(WH_GETMESSAGE, Some(note_taken), None, GetCurrentThreadId()) }
                .inspect_err(|why| log::warn!("the video's window may be found wrongly: {why}"))
                .ok();
        }
    }

    /// Whether content of `size` (pixels) has the shape kept, give or take a pixel's rounding.
    pub(super) fn fits(&self, (width, height): (i32, i32)) -> bool {
        self.shared.ratio.get().is_some_and(|ratio| (f64::from(width) - f64::from(height) * ratio).abs() <= 2.0)
    }

    /// The view was put at `at`: with a shape to keep or held, the window it fills is found;
    /// it keeps the shape from now on, and is kept out of sight when held: then it is returned,
    /// once, to be revealed with [`reveal`].
    pub(super) fn placed(&mut self, at: &Placement) -> Option<HWND> {
        if self.window.is_some() || (self.shared.ratio.get().is_none() && !self.held) {
            return None;
        }
        let window = window_filled_by(at)?;
        let data = (&raw const *self.shared) as usize;
        // SAFETY: `shared` outlives the subclass: it is removed in `drop` or when the window goes.
        // Its address tells it from another video's on the same window.
        if !unsafe { SetWindowSubclass(window, Some(keep_shape), data, data) }.as_bool() {
            return None;
        }
        self.window = Some(window);
        self.unhook();
        if !self.held {
            return None;
        }
        // Another window caught as it showed is not this one's: it shows.
        let caught = CAUGHT.with(|caught| caught.replace(0));
        if caught != 0 && caught != window.0 as isize {
            cloak(HWND(caught as *mut _), false);
        }
        cloak(window, true);
        Some(window)
    }

    fn unhook(&mut self) {
        for hook in [self.hook.take(), self.catch.take()].into_iter().flatten() {
            // SAFETY: a hook set in `look` or `hold`, on this thread.
            unsafe {
                let _ = UnhookWindowsHookEx(hook);
            }
        }
    }
}

impl Drop for WindowShape {
    fn drop(&mut self) {
        self.unhook();
        // Gone before its window was found: the window it caught shows.
        if self.held && self.window.is_none() {
            let caught = CAUGHT.with(|caught| caught.replace(0));
            if caught != 0 {
                cloak(HWND(caught as *mut _), false);
            }
        }
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
        _ if message == revealing() => cloak(window, false),
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

/// The message that reveals a held window, on its own thread (from [`reveal`]).
fn revealing() -> u32 {
    static MESSAGE: OnceLock<u32> = OnceLock::new();
    // SAFETY: a plain call with a constant string.
    *MESSAGE.get_or_init(|| unsafe { RegisterWindowMessageW(w!("Listenook.mpv.reveal")) })
}

/// Shows held `window` (the [`WindowShape::placed`] returned), from any thread: once the frame
/// its thread draws now is done, so the window shows with what it draws.
pub(super) fn reveal(window: isize) {
    // SAFETY: posting by handle; a window gone meanwhile ignores it.
    let _ = unsafe { PostMessageW(Some(HWND(window as *mut _)), revealing(), WPARAM(0), LPARAM(0)) };
}

/// Keeps `window` out of sight (cloaked: drawn and composed, not shown), or shows it again, from
/// any thread of the app.
fn cloak(window: HWND, on: bool) {
    let on = if on { TRUE } else { FALSE };
    // SAFETY: the window is the app's; the attribute takes a BOOL, which outlives the call.
    let set = unsafe { DwmSetWindowAttribute(window, DWMWA_CLOAK, (&raw const on).cast(), size_of::<BOOL>() as u32) };
    if let Err(why) = set {
        log::warn!("the video's window cannot be kept out of sight while it opens: {why}");
    }
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
