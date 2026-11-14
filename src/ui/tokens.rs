use nsh_base::theme;
use nsh_core::{element::StyleRefinement, prelude::*};

fn role(name: &str, fallback: AdaptiveColor) -> AdaptiveColor {
    theme().color(name).unwrap_or(fallback)
}

pub fn primary_hover() -> AdaptiveColor {
    role("primary-hover", theme().primary)
}

pub fn primary_active() -> AdaptiveColor {
    role("primary-active", theme().primary)
}

pub fn success() -> AdaptiveColor {
    role("success", theme().primary)
}

pub fn warning() -> AdaptiveColor {
    role("warning", theme().destructive)
}

pub fn control_border() -> AdaptiveColor {
    role("control-border", theme().input)
}

pub fn hover_wash() -> AdaptiveColor {
    role("hover", theme().muted)
}

pub fn highlight() -> AdaptiveColor {
    role("highlight", theme().accent)
}

pub fn highlight_foreground() -> AdaptiveColor {
    role("highlight-foreground", theme().foreground)
}

pub fn window_close() -> AdaptiveColor {
    role("window-close", theme().destructive)
}

pub fn window_minimize() -> AdaptiveColor {
    role("window-minimize", warning())
}

pub fn window_zoom() -> AdaptiveColor {
    role("window-zoom", success())
}

pub fn stage() -> AdaptiveColor {
    role("stage", theme().foreground)
}

pub fn scrim() -> AdaptiveColor {
    role("scrim", theme().foreground).opacity(0.45)
}

pub fn radius() -> Length {
    theme().radius.into()
}

pub fn radius_sm() -> Length {
    px(theme().number("radius-sm").unwrap_or(6.0)).into()
}

pub fn radius_lg() -> Length {
    px(theme().number("radius-lg").unwrap_or(12.0)).into()
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

pub const POPUP_STARTING: &str = "opacity-0 scale-95 transition-all duration-200 ease-out";
pub const POPUP_ENDING: &str = "opacity-0 scale-95 transition-all duration-150 ease-in";

pub fn focus_ring(s: StyleRefinement) -> StyleRefinement {
    s.outline(px(2.0)).outline_color(|| theme().ring).outline_offset(px(2.0))
}

pub fn sidebar_material() -> MacOsBackdrop {
    let mut backdrop = MacOsBackdrop::default();
    backdrop.material = MacOsBackdropMaterial::Sidebar;
    backdrop.blending = MacOsBackdropBlending::BehindWindow;
    backdrop.state = MacOsBackdropState::FollowsWindowActiveState;
    backdrop
}

pub fn bar_glass(s: StyleRefinement) -> StyleRefinement {
    s.glass_effect(nsh_core::GlassEffect::Regular)
        .border_1()
        .border_color(|| theme().border.opacity(0.6))
        .bg(|| theme().card.opacity(0.6))
        .shadow_sm()
}

pub fn glass(s: StyleRefinement) -> StyleRefinement {
    s.glass_effect(nsh_core::GlassEffect::Regular).backdrop_blur(px(24.0)).bg(|| stage().opacity(0.3))
}
