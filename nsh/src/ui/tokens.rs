//! The app's design tokens: the roles `theme.json` adds to the theme, the
//! radius scale and the motion scale. Every color in the app comes from
//! `nsh_base::theme()` or from here.

use nsh_base::theme;
use nsh_core::{element::StyleRefinement, prelude::*};

fn role(name: &str, fallback: AdaptiveColor) -> AdaptiveColor {
    theme().color(name).unwrap_or(fallback)
}

/// The primary button under the pointer.
pub fn primary_hover() -> AdaptiveColor {
    role("primary-hover", theme().primary)
}

/// The primary button pressed.
pub fn primary_active() -> AdaptiveColor {
    role("primary-active", theme().primary)
}

/// Something finished well.
pub fn success() -> AdaptiveColor {
    role("success", theme().primary)
}

/// Something needs the user's attention but did not fail.
pub fn warning() -> AdaptiveColor {
    role("warning", theme().destructive)
}

/// The fill of the sentence being played.
pub fn highlight() -> AdaptiveColor {
    role("highlight", theme().accent)
}

/// Text on [`highlight`].
pub fn highlight_foreground() -> AdaptiveColor {
    role("highlight-foreground", theme().foreground)
}

/// The player window's own close, minimize and full-screen buttons.
pub fn window_close() -> AdaptiveColor {
    role("window-close", theme().destructive)
}

/// See [`window_close`].
pub fn window_minimize() -> AdaptiveColor {
    role("window-minimize", warning())
}

/// See [`window_close`].
pub fn window_zoom() -> AdaptiveColor {
    role("window-zoom", success())
}

/// What a video fills the screen against.
pub fn stage() -> AdaptiveColor {
    role("stage", theme().foreground)
}

/// The dimming layer behind a dialog.
pub fn scrim() -> AdaptiveColor {
    role("scrim", theme().foreground).opacity(0.45)
}

/// The radius of controls and popups.
pub fn radius() -> Length {
    theme().radius.into()
}

/// The radius of small parts: badges, checkboxes, inset rows.
pub fn radius_sm() -> Length {
    px(theme().number("radius-sm").unwrap_or(6.0)).into()
}

/// The radius of containers that hold controls: cards, dialogs.
pub fn radius_lg() -> Length {
    px(theme().number("radius-lg").unwrap_or(12.0)).into()
}

/// Durations in milliseconds.
pub mod motion {
    use nsh_core::{LayoutAnimation, LayoutCurve, LayoutTransition, prelude::*};

    /// Call just before a change that opens or closes a region (the
    /// sidebar, a side panel): what it moves slides to its new place and
    /// what appears or leaves fades, instead of everything jumping.
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

    /// A hover wash, a color change.
    pub const INSTANT: f32 = 120.0;
    /// A press, a control's state.
    pub const FAST: f32 = 180.0;
    /// Moving into place: a selection, a popup leaving.
    pub const BASE: f32 = 240.0;
    /// A pressed button's scale.
    pub const PRESS_SCALE: f32 = 0.97;
    /// A pressed icon button's scale.
    pub const PRESS_SCALE_ICON: f32 = 0.94;
}

/// The scale a pressed control takes: 1 when the user asks for less motion.
pub fn press_scale(icon: bool) -> f32 {
    if reduce_motion() {
        1.0
    } else if icon {
        motion::PRESS_SCALE_ICON
    } else {
        motion::PRESS_SCALE
    }
}

/// The one surface of menus, popovers and selects.
/// The surface of a menu. On a phone a menu is a sheet that rises from
/// the bottom of the screen, across its width: with room inside and clear
/// of the home indicator.
pub fn menu_surface(s: StyleRefinement) -> StyleRefinement {
    if !crate::platform::is_phone() {
        return popup_surface(s);
    }
    s.px_2()
        .pt_2()
        .pb(px(28.0))
        .rounded(radius_lg)
        .border_1()
        .border_color(|| theme().border)
        .bg(|| theme().popover)
        .shadow_xl()
}

pub fn popup_surface(s: StyleRefinement) -> StyleRefinement {
    s.min_w(px(200.0))
        .p_1()
        .rounded(radius)
        .border_1()
        .border_color(|| theme().border)
        .bg(|| theme().popover)
        .shadow_lg()
}

/// Where a popup starts from and leaves to: slightly smaller and clear.
pub const POPUP_STARTING: &str = "opacity-0 scale-95 transition-all duration-200 ease-out";
/// See [`POPUP_STARTING`].
pub const POPUP_ENDING: &str = "opacity-0 scale-95 transition-all duration-150 ease-in";

/// The keyboard's focus ring, outside the control.
pub fn focus_ring(s: StyleRefinement) -> StyleRefinement {
    s.outline(px(2.0)).outline_color(|| theme().ring).outline_offset(px(2.0))
}

/// The system's sidebar material on a Mac: what is behind the window comes
/// through it, as in the system's own apps.
pub fn sidebar_material() -> MacOsBackdrop {
    let mut backdrop = MacOsBackdrop::default();
    backdrop.material = MacOsBackdropMaterial::Sidebar;
    backdrop.blending = MacOsBackdropBlending::BehindWindow;
    backdrop.state = MacOsBackdropState::FollowsWindowActiveState;
    backdrop
}

/// The surface of a button in a bar the app draws where the system's
/// header would be: the system's own glass where it has it (iOS 26), a
/// raised card elsewhere.
pub fn bar_glass(s: StyleRefinement) -> StyleRefinement {
    s.glass_effect(nsh_core::GlassEffect::Regular)
        .border_1()
        .border_color(|| theme().border.opacity(0.6))
        .bg(|| theme().card.opacity(0.6))
        .shadow_sm()
}

/// A surface floating over a picture: Apple's Liquid Glass where the
/// system has it (iOS 26, macOS 26), a dark frosted panel elsewhere.
pub fn glass(s: StyleRefinement) -> StyleRefinement {
    s.glass_effect(nsh_core::GlassEffect::Regular).backdrop_blur(px(24.0)).bg(|| stage().opacity(0.3))
}
