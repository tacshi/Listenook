//! The app's styled component layer. Pages compose these and layout
//! primitives; they do not style `nsh_base` controls themselves.

mod button;
mod form;
mod icons;
mod layout;
mod overlay;
pub(crate) mod tokens;

pub(crate) use button::{
    Size, Variant, bar_button, button, header_button, icon_button, icon_text_button, tip, toggle_icon_button,
};
pub(crate) use form::{
    checkbox, field, focused_search_field, hint, progress_bar, search_field, segmented, select, slider,
    slider_on_picture, switch, text_area, text_field,
};
pub(crate) use icons::{Icon, icon, icon_of, tray_icon_url};
pub(crate) use layout::{
    PAGE_INSET, Status, badge, card, chip, empty_state, key_cap, list_row, section, separator, spinner, veil,
};
pub(crate) use overlay::{
    Tone, confirm_destructive, menu, menu_action, menu_choice, menu_danger, menu_divider, menu_toggle, modal,
    modal_actions, modal_sized, popover, toast, toast_host,
};
