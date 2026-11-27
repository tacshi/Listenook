//! The design's named values: its colors by role, its corner radii and its surfaces, each read
//! from the theme with a fallback, so the whole app takes them from one place.

use nsh_base::theme;
use nsh_core::{element::StyleRefinement, prelude::*};

/// A color, by what it is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ink {
    PrimaryHover,
    PrimaryActive,
    Success,
    Warning,
    /// Listening time in charts: an emerald green.
    Listen,
    /// Practice time in charts: a hot orange beside the green.
    Practice,
    /// What is being recorded: the red of a recording light. Only for the recording itself
    /// (its dot, its live meter), never for an action.
    Recording,
    ControlBorder,
    HoverWash,
    Highlight,
    /// A search match in the transcript: an amber wash under the words.
    Found,
    HighlightForeground,
    WindowClose,
    WindowMinimize,
    WindowZoom,
    Stage,
    Scrim,
}

fn role(name: &str, fallback: AdaptiveColor) -> AdaptiveColor {
    theme().color(name).unwrap_or(fallback)
}

/// The color for `ink`, in the theme now.
pub fn ink(which: Ink) -> AdaptiveColor {
    match which {
        Ink::PrimaryHover => role("primary-hover", theme().primary),
        Ink::PrimaryActive => role("primary-active", theme().primary),
        Ink::Success => role("success", theme().primary),
        Ink::Warning => role("warning", theme().destructive),
        Ink::Listen => role("listen", theme().chart_1),
        Ink::Practice => role("practice", theme().chart_2),
        Ink::Recording => role("recording", theme().destructive),
        Ink::ControlBorder => role("control-border", theme().input),
        Ink::HoverWash => role("hover", theme().muted),
        Ink::Highlight => role("highlight", theme().accent),
        Ink::Found => ink(Ink::Warning).opacity(0.28),
        Ink::HighlightForeground => role("highlight-foreground", theme().foreground),
        Ink::WindowClose => role("window-close", theme().destructive),
        Ink::WindowMinimize => role("window-minimize", ink(Ink::Warning)),
        Ink::WindowZoom => role("window-zoom", ink(Ink::Success)),
        Ink::Stage => role("stage", theme().foreground),
        Ink::Scrim => role("scrim", theme().foreground).opacity(0.45),
    }
}

/// The shadow under a video's subtitles, which have nothing behind them: it keeps the white text
/// readable on a bright picture. nsh's text-shadow presets are too faint for text on a video.
pub fn subtitle_shadow() -> TextShadow {
    TextShadow {
        color: ink(Ink::Stage).dark.opacity(0.9).into(),
        offset_x: px(0.0),
        offset_y: px(1.0),
        radius: px(4.0),
    }
}

/// How round a corner is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Corner {
    /// The smallest parts: a calendar's days, a key's swatches.
    Tiny,
    Small,
    Medium,
    Large,
}

/// The radius of `corner`, in the theme now.
pub fn corner(which: Corner) -> Length {
    match which {
        Corner::Tiny => px(2.0).into(),
        Corner::Small => px(theme().number("radius-sm").unwrap_or(6.0)).into(),
        Corner::Medium => theme().radius.into(),
        Corner::Large => px(theme().number("radius-lg").unwrap_or(12.0)).into(),
    }
}

/// What a floating part of the app is made of.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Surface {
    /// A popover or a menu on a computer.
    Popup,
    /// A menu: a popup on a computer, a larger sheet on a phone.
    Menu,
    /// A bar floating over what it shows.
    BarGlass,
    /// Glass over the stage, as the player's controls are.
    Glass,
}

/// Styles `s` as `surface`.
pub fn surface(which: Surface, s: StyleRefinement) -> StyleRefinement {
    match which {
        Surface::Popup => s
            .min_w(px(200.0))
            .p_1()
            .rounded(|| corner(Corner::Medium))
            .border_1()
            .border_color(|| theme().border)
            .bg(|| theme().popover)
            .shadow_lg(),
        Surface::Menu if !crate::platform::is_phone() => surface(Surface::Popup, s),
        Surface::Menu => s
            .p_2()
            .rounded(|| corner(Corner::Large))
            .border_1()
            .border_color(|| theme().border)
            .bg(|| theme().popover)
            .shadow_xl(),
        Surface::BarGlass => s
            .glass_effect(nsh_core::GlassEffect::Regular)
            .border_1()
            .border_color(|| theme().border.opacity(0.6))
            .bg(|| theme().card.opacity(0.6))
            .shadow_sm(),
        // Black, the picture showing through: no blur, which macOS draws as gray frosted glass.
        Surface::Glass => s.bg(|| ink(Ink::Stage).opacity(0.25)),
    }
}

pub mod motion {
    use nsh_core::{LayoutAnimation, LayoutCurve, LayoutTransition, prelude::*};

    pub fn reflow() {
        if reduce_motion() {
            return;
        }
        let fade = LayoutTransition::new(LayoutCurve::EaseOut, FAST);
        animate_layout(LayoutAnimation {
            create: Some(fade),
            update: Some(LayoutTransition::new(LayoutCurve::EaseInEaseOut, BASE)),
            delete: Some(fade),
        });
    }

    pub const INSTANT: f32 = 120.0;
    pub const FAST: f32 = 180.0;
    pub const BASE: f32 = 240.0;
    pub const PRESS_SCALE: f32 = 0.97;
    pub const PRESS_SCALE_ICON: f32 = 0.94;
}

pub fn press_scale(icon: bool) -> f32 {
    if reduce_motion() {
        1.0
    } else if icon {
        motion::PRESS_SCALE_ICON
    } else {
        motion::PRESS_SCALE
    }
}

pub const POPUP_STARTING: &str = "opacity-0 scale-95 transition-all duration-200 ease-out";
pub const POPUP_ENDING: &str = "opacity-0 scale-95 transition-all duration-150 ease-in";

pub fn sidebar_material() -> MacOsBackdrop {
    let mut backdrop = MacOsBackdrop::default();
    backdrop.material = MacOsBackdropMaterial::Sidebar;
    backdrop.blending = MacOsBackdropBlending::BehindWindow;
    backdrop.state = MacOsBackdropState::FollowsWindowActiveState;
    backdrop
}
