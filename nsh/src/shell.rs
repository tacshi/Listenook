//! The app shell: the sidebar, the place or the open recording beside it,
//! the podcast player that outlives pages, and the window's commands.

use listenook_core::{format::clock, l10n::Lang};
use nsh_base::{nav_page, nav_stack, theme};
use nsh_core::{
    desktop::{MenuRole, TitleBarOptions, TitleBarStyle, WindowAttributes},
    element::desktop::{
        MenuItem, current_window, register_global_shortcut, set_application_menu, set_tray, title_bar, tray,
        unregister_global_shortcut,
    },
    mobile::TabBarItem,
    platform::Os,
    prelude::*,
};

use crate::{
    pages, platform,
    services::media,
    state::{
        Filter, Place, l,
        podcast::{RATES, rate_label},
        store, tr,
    },
    ui::{
        self, Icon, Size, Variant, confirm_destructive, field, icon, icon_button, menu, menu_action, menu_danger,
        modal, modal_actions, slider, text_field, toggle_icon_button,
        tokens::{self, motion},
    },
    util,
};

/// The height of the band the window's controls sit in.
const BAR: f32 = 44.0;
/// The keystroke that plays or pauses from any app, when turned on.
pub(crate) const GLOBAL_PLAY_PAUSE: &str = "ctrl+alt+space";
/// The room between the window's own controls and what the bar shows.
const CONTROLS_GAP: f32 = 12.0;

/// The whole window.
pub(crate) fn shell() -> impl IntoElement {
    let store = store();
    let mut bar = TitleBarOptions::default();
    bar.style = TitleBarStyle::Hidden;
    bar.height = Some(px(BAR));
    let mut attributes = WindowAttributes::default();
    attributes.title_bar = Some(bar);
    current_window().set(attributes);

    // What the system asks (media keys, the menu-bar item) arrives on its
    // own threads and is handed over here.
    let ticks = std::cell::Cell::new(0_u32);
    set_interval(std::time::Duration::from_millis(100), move || {
        media::pump();
        // Twice a second: a hardware keyboard's keys reach the shortcuts.
        ticks.set(ticks.get().wrapping_add(1));
        if ticks.get().is_multiple_of(5) {
            crate::services::keep_keys();
        }
        // And the files picked in the system's file browser on a phone.
        let picked = crate::services::take_picked();
        if !picked.is_empty() {
            util::import_picked(picked);
        }
    });
    // The app can stay in the tray (the menu bar on a Mac): closing the
    // window then hides it, and transcriptions, downloads and the watched
    // folder go on.
    let in_tray = move || platform::has_tray() && store.tray_enabled();
    // Opened at login (`--background`), the app starts in the tray with
    // no window in the way, as long as there is a tray icon to open it by.
    if std::env::args().any(|argument| argument == "--background") && untracked(in_tray) {
        current_window().hide();
    }
    // In the Dock or out of it, as set.
    effect(move || crate::services::set_dock_icon(store.dock_visible()));
    let show_window = move || {
        store.set_video_only(false);
        current_window().show();
        current_window().focus();
    };
    effect(move || {
        let stays = in_tray();
        if stays {
            let mut items = vec![MenuItem::new(tr("Open Listenook").to_string()).on_select(show_window)];
            // Only with a folder to watch.
            if !store.monitor().folder_path.is_empty() {
                let watching = if store.monitor().paused { "Resume watching" } else { "Pause watching" };
                items.push(
                    MenuItem::new(tr(watching).to_string())
                        .on_select(move || store.set_monitor_paused(!store.monitor().paused)),
                );
            }
            items.push(MenuItem::new(tr("Settings…").to_string()).on_select(move || {
                show_window();
                store.settings_open().set(true);
            }));
            items.push(MenuItem::separator());
            items.push(MenuItem::new(tr("Quit Listenook").to_string()).on_select(nsh_core::element::desktop::quit));
            set_tray(
                tray().icon(ui::tray_icon_url()).tooltip("Listenook").on_click(move |_| show_window()).menu(items),
            );
        } else {
            set_tray(None);
        }
        let mut attributes = WindowAttributes::default();
        attributes.close_on_press = Some(!stays);
        current_window().set(attributes);
    });
    // Files the system opens the app with (Open With, a double click, a
    // drop on its icon): a video plays, other media goes to the Library.
    let launched = std::time::Instant::now();
    let open_media = move |paths: Vec<String>| match paths.iter().find(|path| pages::is_video(path)) {
        Some(video) => {
            store.open_video(video);
            // Launched to play it: the player is all that shows.
            if launched.elapsed() < std::time::Duration::from_secs(2) && !platform::is_phone() {
                store.set_video_only(true);
                // Once the window is up: at the very start it is not
                // there to hide yet, and would show after all.
                spawn(async move {
                    for wait in [0, 60, 250] {
                        timer(std::time::Duration::from_millis(wait)).await;
                        if store.video_only() {
                            current_window().hide();
                        }
                    }
                });
            }
        }
        None => {
            util::add_media(paths);
            show_window();
        }
    };
    let open_paths = move |paths: Vec<String>| {
        // On a phone or a tablet what another app hands over (its share
        // sheet, "Open in") goes into the Library, kept with the app's own.
        if platform::is_phone() && paths.iter().any(|path| listenook_core::subtitles::is_media(path)) {
            let taken = util::import_opened(paths);
            if taken > 0 {
                store.go(Place::Library);
                ui::toast(ui::Tone::Success, tr("Added to your library"));
            } else {
                ui::toast(ui::Tone::Error, tr("That file could not be added."));
            }
            return;
        }
        open_media(paths)
    };
    // Opened with a video on the command line (Windows' "Open with").
    if let Some(video) =
        std::env::args().nth(1).filter(|path| pages::is_video(path) && std::path::Path::new(path).is_file())
    {
        open_paths(vec![video]);
    }
    spawn(async move {
        loop {
            let files = next_open_files().await;
            open_paths(files.iter().filter_map(|path| path.to_str().map(str::to_owned)).collect());
        }
    });
    // On Windows and Linux a second launch hands its arguments over.
    spawn(async move {
        loop {
            let launch = next_second_instance().await;
            let paths: Vec<String> = launch
                .args
                .iter()
                .skip(1)
                .filter(|arg| std::path::Path::new(arg.as_str()).is_file())
                .cloned()
                .collect();
            if !paths.is_empty() {
                open_paths(paths);
            }
        }
    });
    current_window().on_focus_change(move |focused| store.set_focused(focused));
    // A key that plays or pauses whichever app is in front, for those who
    // turn it on.
    effect(move || {
        let on = store.setting(|s| s.extra.get("global_play_pause").and_then(|v| v.as_bool()).unwrap_or(false));
        if on {
            drop(register_global_shortcut(GLOBAL_PLAY_PAUSE, || media::press(media::Command::Toggle)));
        } else {
            unregister_global_shortcut(GLOBAL_PLAY_PAUSE);
        }
    });
    current_window().on_close_press(move |_| {
        if untracked(in_tray) {
            current_window().hide();
        }
    });

    // The watched folder is looked at every few seconds; a file is taken
    // on the second look that finds it unchanged.
    set_interval(std::time::Duration::from_secs(5), move || store.scan_watched_folder());
    // On a computer the commands are the menu bar's, which carries their
    // shortcuts; elsewhere a hardware keyboard reaches them directly.
    if is_desktop() {
        effect(move || {
            store.lang();
            set_application_menu(application_menu());
        });
    } else {
        on_key("mod+1", move |_| store.show(Filter::All));
        on_key("mod+2", move |_| store.go(Place::Podcasts));
        on_key("mod+,", move |_| store.settings_open().set(true));
        on_key("mod+o", |_| util::pick_media());
        on_key("mod+b", move |_| store.toggle_sidebar());
        on_key("mod+shift+o", |_| util::pick_video());
    }
    // Going somewhere from the drawer puts it away.
    effect(move || {
        let _ = (store.place(), store.filter(), store.open_job_id());
        untracked(|| store.set_drawer(false));
    });
    let lang = computed(move || store.lang());
    let shown_in = std::cell::Cell::new(untracked(|| store.lang()));
    view()
        .flex_1()
        .flex_row()
        .on_file_drop(|event: &FileDropEvent| {
            util::add_media(event.uris.iter().map(|uri| util::path_of_url(uri)).collect());
        })
        .child(when(move || !store.immersive() && !store.sidebar_hidden() && !platform::compact(), sidebar))
        .child(
            view()
                .flex_1()
                .min_w(px(0.0))
                .child(view().flex_1().min_h(px(0.0)).child(if platform::is_phone() {
                    stacked(lang).into_element()
                } else {
                    dynamic(move || {
                        // Built again in a new language: some labels are read
                        // once, when their control is made.
                        // In place, without the entrance a new page makes.
                        let translated = shown_in.replace(lang.get()) != lang.get();
                        // The open recording covers the place it was opened from.
                        let (video, open, place) = (store.open_video_path(), store.open_job_id(), store.place());
                        untracked(|| match video {
                            Some(path) => pages::player(&path).into_element(),
                            None => page(open, place, !translated),
                        })
                    })
                    .into_element()
                }))
                .child(when(
                    move || {
                        store.podcast.playing().is_some()
                            && store.open_job_id().is_none()
                            && store.open_video_path().is_none()
                    },
                    mini_player,
                ))
                .child(when(tab_bar_shown, tab_bar)),
        )
        .child(when(move || store.podcast.playing().is_some(), podcast_player))
        // In a narrow window the sidebar comes out over the page.
        .child(when(
            move || platform::compact() && store.drawer() && !store.immersive(),
            move || {
                // Escape puts it away, as a press beside it does.
                on_key("escape", move |_| store.set_drawer(false));
                view()
                    .absolute()
                    .inset_0()
                    .flex_row()
                    .child(sidebar())
                    .child(view().flex_1().bg(ui::tokens::scrim).on_press(move || store.set_drawer(false)))
            },
        ))
        .child(pages::settings_dialog())
        .child(pages::subtitle_choice_dialog())
}

/// What is pushed over a place on a phone or a tablet.
#[derive(Debug, Clone, PartialEq)]
enum Pushed {
    /// A podcast, by its feed's address.
    Show(String),
    Reader(String),
    Video(String),
}

/// The pages of a phone or a tablet, in the system's own stack: the place
/// at the bottom, the open recording pushed over it with the system's
/// transition and taken off by its back swipe (or Android's back button).
fn stacked(lang: Memo<Lang>) -> impl IntoElement {
    let store = store();
    // Keyed by the language too: a page is made again in a new one.
    let pushed = computed(move || {
        let lang = lang.get();
        let mut pages = Vec::new();
        if let Some(show) = store.podcast.open_show.get().filter(|_| store.place() == Place::Podcasts) {
            pages.push((lang, Pushed::Show(show)));
        }
        if let Some(id) = store.open_job_id() {
            pages.push((lang, Pushed::Reader(id)));
        }
        if let Some(path) = store.open_video_path() {
            pages.push((lang, Pushed::Video(path)));
        }
        pages
    });
    // Android's back button puts the drawer away before it leaves a page.
    on_back_press(move || {
        let open = store.drawer_now();
        if open {
            store.set_drawer(false);
        }
        open
    });
    // The header in the app's colors, its buttons in the accent.
    let colors = |s: nsh_core::element::StyleRefinement| {
        s.bg(|| theme().background).text_color(|| theme().foreground).tint_color(|| theme().primary)
    };
    nav_stack()
        .flex_1()
        .child(
            nav_page()
                .title(move || tr(if store.place() == Place::Podcasts { "Podcasts" } else { "Library" }))
                .header_style_with(colors)
                // The system's own sidebar button on an iPhone or an iPad;
                // elsewhere this one is what shows.
                .header_left_symbol("sidebar.left")
                .header_left(ui::header_button(Icon::Sidebar, tr("Sidebar"), move || store.toggle_sidebar()))
                // The system draws this button whether or not it holds
                // anything, so each place has something to add. As at the
                // left, the system's own glyph shows on an iPhone or an iPad.
                .header_right_symbol("plus")
                .header_right(
                    view().child(
                        when(
                            move || store.place() == Place::Library,
                            || ui::header_button(Icon::Plus, tr("Add media"), util::pick_media),
                        )
                        .otherwise(move || {
                            ui::header_button(Icon::Plus, tr("Add by URL"), move || store.podcast.adding.set(true))
                        }),
                    ),
                )
                .bg(|| theme().background)
                .child(dynamic(move || {
                    lang.get();
                    let place = store.place();
                    untracked(|| page(None, place, false))
                })),
        )
        .child(each(
            move || pushed.get(),
            |page: &(Lang, Pushed)| format!("{page:?}"),
            move |page, _| {
                let screen = nav_page().hides_bottom_bar_when_pushed(true).bg(|| theme().background);
                // Beside the sidebar a pushed page keeps its button, next
                // to the way back: or the sidebar could not be put away
                // from here. A phone's page has the drawer's on the places.
                let screen = if untracked(platform::compact) {
                    screen
                } else {
                    screen.header_left_symbol("sidebar.left").header_left(ui::header_button(
                        Icon::Sidebar,
                        tr("Sidebar"),
                        move || store.toggle_sidebar(),
                    ))
                };
                match page.get_untracked().1 {
                    // A show keeps the places' tab bar under it.
                    Pushed::Show(url) => screen
                        .hides_bottom_bar_when_pushed(false)
                        .title(move || {
                            store.podcast.feed(&url).map(|feed| SharedString::from(feed.title)).unwrap_or_default()
                        })
                        .header_style_with(colors)
                        .child(pages::podcast_show())
                        .on_dismiss(move || store.podcast.open_show.set(None)),
                    Pushed::Reader(id) => {
                        let job = id.clone();
                        screen
                            .title(move || {
                                store.job(&job).map(|job| SharedString::from(job.title())).unwrap_or_default()
                            })
                            // The reader draws its own bar: the system's
                            // cannot be put away while its page shows, and a
                            // video filling the screen has it to itself.
                            .header_visible(false)
                            .child(pages::reader(&id))
                            .on_dismiss(move || store.close_reader())
                    }
                    // The player is a dark stage with a bar of its own.
                    Pushed::Video(path) => {
                        screen.header_visible(false).child(pages::player(&path)).on_dismiss(move || store.close_video())
                    }
                }
            },
        ))
}

/// Whether the system draws the pages' header: the title, the way back and
/// the sidebar's button are its own then, and a page's bar keeps the rest.
pub(crate) fn system_header() -> bool {
    platform::is_phone()
}

/// Whether the system's tab bar is at the bottom: on a phone, or a tablet
/// window as narrow as one, while no recording is open over the places.
pub(crate) fn tab_bar_shown() -> bool {
    let store = store();
    platform::is_phone()
        && platform::compact()
        && store.open_job_id().is_none()
        && store.open_video_path().is_none()
        && !store.immersive()
}

/// The system's tab bar: the places, and Settings.
fn tab_bar() -> impl IntoElement {
    let store = store();
    // An SF Symbol on iOS, one of the system's drawables on Android.
    let symbol = |ios: &'static str, android: &'static str| if os() == Os::Ios { ios } else { android };
    nsh_core::mobile::tab_bar()
        .items(move || {
            vec![
                TabBarItem::new(tr("Library")).icon(symbol("books.vertical", "android:ic_menu_agenda")),
                TabBarItem::new(tr("Podcasts"))
                    .icon(symbol("antenna.radiowaves.left.and.right", "android:ic_menu_slideshow")),
                TabBarItem::new(tr("Settings")).icon(symbol("gearshape", "android:ic_menu_preferences")),
            ]
        })
        // Settings is a sheet over the place it was asked from: its tab is
        // lit while the sheet is up.
        .selected_index(move || {
            if store.settings_open().get() {
                2_u32
            } else if store.place() == Place::Podcasts {
                1
            } else {
                0
            }
        })
        .on_change(move |index: &u32| match index {
            0 => store.show(Filter::All),
            1 => store.go(Place::Podcasts),
            _ => store.settings_open().set(true),
        })
}

/// The menu bar: the app's commands with their shortcuts, and the
/// system's own (editing, the window) under their usual names.
fn application_menu() -> Vec<MenuItem> {
    let store = store();
    let named = |label: &'static str| tr(label).to_string();
    let role = |role: MenuRole, label: &'static str| MenuItem::role(role).label(named(label));
    let settings =
        MenuItem::new(named("Settings…")).shortcut("mod+,").on_select(move || store.settings_open().set(true));
    let mut menus = Vec::new();
    // A Mac's first menu is the app's own; elsewhere its items are in File.
    let mac = os() == Os::MacOs;
    if mac {
        menus.push(MenuItem::submenu(
            "Listenook",
            [
                role(MenuRole::About, "About Listenook"),
                MenuItem::separator(),
                settings.clone(),
                MenuItem::separator(),
                role(MenuRole::Hide, "Hide Listenook"),
                role(MenuRole::HideOthers, "Hide Others"),
                role(MenuRole::ShowAll, "Show All"),
                MenuItem::separator(),
                role(MenuRole::Quit, "Quit Listenook"),
            ],
        ));
    }
    let mut file = vec![
        MenuItem::new(named("Add media…")).shortcut("mod+o").on_select(util::pick_media),
        MenuItem::new(named("Open video…")).shortcut("mod+shift+o").on_select(util::pick_video),
        MenuItem::separator(),
        role(MenuRole::Close, "Close Window"),
    ];
    if !mac {
        file.extend([MenuItem::separator(), settings, MenuItem::separator(), role(MenuRole::Quit, "Quit Listenook")]);
    }
    menus.push(MenuItem::submenu(named("File"), file));
    menus.push(MenuItem::submenu(
        named("Edit"),
        [
            role(MenuRole::Undo, "Undo"),
            role(MenuRole::Redo, "Redo"),
            MenuItem::separator(),
            role(MenuRole::Cut, "Cut"),
            role(MenuRole::Copy, "Copy"),
            role(MenuRole::Paste, "Paste"),
            role(MenuRole::SelectAll, "Select All"),
        ],
    ));
    menus.push(MenuItem::submenu(
        named("View"),
        [
            MenuItem::new(named("Library")).shortcut("mod+1").on_select(move || store.show(Filter::All)),
            MenuItem::new(named("Podcasts")).shortcut("mod+2").on_select(move || store.go(Place::Podcasts)),
            MenuItem::separator(),
            MenuItem::new(named("Show or Hide Sidebar")).shortcut("mod+b").on_select(move || store.toggle_sidebar()),
            role(MenuRole::ToggleFullScreen, "Enter or Leave Full Screen"),
        ],
    ));
    // What a Mac calls zooming a window, Windows and Linux call maximizing it.
    let zoom = if mac { "Zoom" } else { "Maximize" };
    menus.push(MenuItem::submenu(named("Window"), [role(MenuRole::Minimize, "Minimize"), role(MenuRole::Zoom, zoom)]));
    menus
}

fn page(open: Option<String>, place: Place, enters: bool) -> AnyElement {
    let content = match (open, place) {
        (Some(id), _) => pages::reader(&id).into_element(),
        (None, Place::Library) => pages::library().into_element(),
        (None, Place::Podcasts) => pages::podcasts().into_element(),
    };
    let page = view().flex_1();
    if enters {
        let entrance = motion().entering(MotionPreset::FadeIn);
        page.bind_motion(&entrance).child(content).into_element()
    } else {
        page.child(content).into_element()
    }
}

/// What the naming dialog is naming.
#[derive(Debug, Clone, PartialEq)]
enum Named {
    NewGroup,
    Group(String),
    NewTag,
    Tag(String),
}

/// The height of a sidebar row under a finger, and the side of the small
/// buttons beside one: the least a touch target may be.
const TOUCH_ROW: f32 = 44.0;

/// The size of the small buttons at the end of the sidebar's rows.
fn trailing_size() -> Size {
    if platform::is_phone() { Size::Md } else { Size::Sm }
}

/// The small "more" menu at the end of a group's or a tag's row: it stays
/// pressed while its menu is open.
fn more(name: &'static str) -> ui::Menu {
    let open = signal(false);
    ui::menu_with(open, ui::menu_trigger(Icon::More, tr(name), trailing_size(), open))
}

/// The room a row without a "more" menu keeps at its end, so the counts
/// of every row stand in one column.
fn trailing_lane() -> View {
    view().w(px(trailing_size().height())).flex_shrink_0()
}

/// A row of the sidebar: a place or a filter of the Library.
fn row(
    glyph: Icon,
    label: impl Fn() -> SharedString + 'static,
    count: impl Fn() -> Option<usize> + Clone + 'static,
    selected: impl Fn() -> bool + Clone + 'static,
    on_press: impl Fn() + 'static,
) -> nsh_base::ButtonElement {
    let (chosen, counted) = (selected.clone(), count.clone());
    // Under a finger the rows are taller and their text is body text.
    let touch = platform::is_phone();
    let (height, slot, glyph_size) = if touch { (TOUCH_ROW, 24.0, 20.0) } else { (32.0, 20.0, 16.0) };
    let label = text(label).flex_1().number_of_lines(1).font_weight(FontWeight::MEDIUM);
    nsh_base::button()
        .selected(selected)
        .on_press(on_press)
        .h(px(height))
        .flex_row()
        .items_center()
        .style_with(move |s| if touch { s.gap_3().px_3() } else { s.gap_2().px_2() })
        .rounded(tokens::radius)
        .transition_colors()
        .duration(motion::INSTANT)
        .hover(|s| s.bg(tokens::hover_wash))
        .active(|s| s.bg(|| theme().input))
        .selected_style(|s| s.bg(|| theme().sidebar_accent))
        .focus_visible(tokens::focus_ring)
        .text_color(move || if chosen() { theme().foreground } else { theme().muted_foreground })
        .child(view().w(px(slot)).items_center().child(icon(glyph, glyph_size)))
        .child(if touch { label.text_base() } else { label.text_sm() })
        .child(when(
            move || counted().is_some_and(|count| count > 0),
            move || {
                let count = count.clone();
                let count = text(move || SharedString::from(count().unwrap_or(0).to_string()));
                if touch { count.text_sm() } else { count.text_xs() }
                    .tabular_nums()
                    .text_color(|| theme().muted_foreground)
            },
        ))
}

/// A section's heading in the sidebar, with the button that adds to it.
fn heading(label: &'static str, add: &'static str, on_add: impl Fn() + 'static) -> impl IntoElement {
    let touch = platform::is_phone();
    let title = text(l(label));
    view()
        .flex_row()
        .items_center()
        .pt_3()
        .child(
            if touch { title.text_sm().px_3() } else { title.text_xs().px_2() }
                .font_weight(FontWeight::MEDIUM)
                .text_color(|| theme().muted_foreground)
                .flex_1()
                .role(AccessibilityRole::Header),
        )
        .child(icon_button(Icon::Plus, tr(add), trailing_size(), on_add))
}

/// The sidebar's width: wider under a finger.
fn sidebar_width() -> f32 {
    if platform::is_phone() { 288.0 } else { 216.0 }
}

/// Whether the page beside the sidebar is as narrow as a phone's: a narrow
/// window, or one the sidebar leaves little of (an iPad held upright).
pub(crate) fn page_narrow() -> bool {
    page_width() < 700.0
}

/// Whether a page puts its panels one above another instead of side by
/// side: where it is narrow, and on a tablet held upright, whose page is
/// taller than it is wide however wide that is.
pub(crate) fn page_stacks() -> bool {
    page_narrow() || (platform::is_phone() && window().height.0 > window().width.0)
}

/// The width of the page beside the sidebar.
pub(crate) fn page_width() -> f32 {
    let store = store();
    let beside = if platform::compact() || store.sidebar_hidden() || store.immersive() { 0.0 } else { sidebar_width() };
    window().width.0 - beside
}

fn sidebar() -> impl IntoElement {
    let store = store();
    let in_library = move |filter: Filter| store.place() == Place::Library && store.filter() == filter;
    // The one dialog that names a group or a tag, new or existing.
    let (naming, named, name) = (signal(false), signal(Named::NewGroup), signal(String::new()));
    let ask = move |what: Named, current: String| {
        batch(|| {
            named.set(what);
            name.set(current);
            naming.set(true);
        });
    };
    let commit = move || {
        let text = name.get_untracked();
        match named.get_untracked() {
            Named::NewGroup => drop(store.add_group(&text)),
            Named::Group(id) => store.rename_group(&id, &text),
            Named::NewTag => drop(store.add_tag(&text)),
            Named::Tag(id) => store.rename_tag(&id, &text),
        }
        naming.set(false);
    };
    view()
        .w(px(sidebar_width()))
        .flex_shrink_0()
        // A Mac's sidebar is the system's material, the desktop showing
        // faintly through; elsewhere the theme's own color.
        .macos_backdrop(Some(tokens::sidebar_material()))
        .bg(|| if os() == Os::MacOs { theme().sidebar.opacity(0.0) } else { theme().sidebar })
        .border_r_1()
        .border_color(|| theme().sidebar_border)
        // The window's controls sit over the top of the sidebar, with the
        // button that puts it away at the other end.
        .child(if system_header() {
            // The system's header has the one button for the sidebar.
            view().h(px(8.0))
        } else {
            view().h(px(BAR)).flex_row().items_center().justify_end().px_2().window_drag(true).child(
                // The bar drags the window; its button must not.
                view()
                    .window_drag(false)
                    .child(icon_button(Icon::Sidebar, tr("Hide sidebar"), Size::Sm, move || store.toggle_sidebar())),
            )
        })
        .child(
            scroll().flex_1().child(
                view()
                    .px_2()
                    .pb_2()
                    .gap(px(2.0))
                    .child(
                        view()
                            .flex_row()
                            .items_center()
                            .child(
                                row(
                                    Icon::Library,
                                    l("Library"),
                                    move || Some(store.count(&Filter::All)),
                                    move || in_library(Filter::All),
                                    move || store.show(Filter::All),
                                )
                                .flex_1(),
                            )
                            .child(trailing_lane()),
                    )
                    .child(
                        view()
                            .flex_row()
                            .items_center()
                            .child(
                                row(
                                    Icon::Clock,
                                    l("In progress"),
                                    move || Some(store.count(&Filter::InProgress)),
                                    move || in_library(Filter::InProgress),
                                    move || store.show(Filter::InProgress),
                                )
                                .flex_1(),
                            )
                            .child(trailing_lane()),
                    )
                    .child(
                        view()
                            .flex_row()
                            .items_center()
                            .child(
                                row(
                                    Icon::Podcast,
                                    l("Podcasts"),
                                    || None,
                                    move || store.place() == Place::Podcasts,
                                    move || store.go(Place::Podcasts),
                                )
                                .flex_1(),
                            )
                            .child(trailing_lane()),
                    )
                    .child(heading("Groups", "New group", move || ask(Named::NewGroup, String::new())))
                    .child(each(
                        move || store.catalog().groups,
                        |group| group.id.clone(),
                        move |group, _| {
                            let id = group.get_untracked().id;
                            let filter = Filter::Group(id.clone());
                            let (counted, selected, shown, deleted) = (filter.clone(), filter.clone(), filter, id);
                            view()
                                .flex_row()
                                .items_center()
                                .child(
                                    row(
                                        Icon::Folder,
                                        move || group.with(|g| SharedString::from(g.name.clone())),
                                        move || Some(store.count(&counted)),
                                        {
                                            let selected = selected.clone();
                                            move || store.place() == Place::Library && store.filter() == selected
                                        },
                                        move || store.show(shown.clone()),
                                    )
                                    .flex_1(),
                                )
                                .child(
                                    more("Group actions")
                                        .child(menu_action(Icon::Pencil, l("Rename…"), {
                                            let id = deleted.clone();
                                            move || ask(Named::Group(id.clone()), group.get_untracked().name)
                                        }))
                                        .child(menu_danger(Icon::Trash, l("Delete group…"), move || {
                                            let id = deleted.clone();
                                            confirm_destructive(
                                                format!("{} “{}”?", tr("Delete group"), group.get_untracked().name),
                                                tr("Its recordings stay in the Library."),
                                                tr("Cancel"),
                                                tr("Delete"),
                                                move || store.delete_group(&id),
                                            );
                                        })),
                                )
                        },
                    ))
                    .child(heading("Tags", "New tag", move || ask(Named::NewTag, String::new())))
                    .child(each(
                        move || store.catalog().tags,
                        |tag| tag.id.clone(),
                        move |tag, _| {
                            let id = tag.get_untracked().id;
                            let filter = Filter::Tag(id.clone());
                            let (counted, selected, shown, deleted) =
                                (filter.clone(), filter.clone(), filter, id.clone());
                            view()
                                .flex_row()
                                .items_center()
                                .child(
                                    row(
                                        Icon::Tag,
                                        move || tag.with(|t| SharedString::from(t.name.clone())),
                                        move || Some(store.count(&counted)),
                                        move || store.place() == Place::Library && store.filter() == selected,
                                        move || store.show(shown.clone()),
                                    )
                                    .flex_1(),
                                )
                                .child(
                                    more("Tag actions")
                                        .child(menu_action(Icon::Pencil, l("Rename…"), move || {
                                            let tag = tag.get_untracked();
                                            ask(Named::Tag(tag.id), tag.name);
                                        }))
                                        .child(menu_danger(Icon::Trash, l("Delete tag…"), move || {
                                            let id = deleted.clone();
                                            confirm_destructive(
                                                format!("{} “{}”?", tr("Delete tag"), tag.get_untracked().name),
                                                tr("It is taken off its recordings, which stay in the Library."),
                                                tr("Cancel"),
                                                tr("Delete"),
                                                move || store.delete_tag(&id),
                                            );
                                        })),
                                )
                        },
                    )),
            ),
        )
        .child(modal(
            naming,
            move || {
                tr(match named.get() {
                    Named::NewGroup => "New group",
                    Named::Group(_) => "Rename group",
                    Named::NewTag => "New tag",
                    Named::Tag(_) => "Rename tag",
                })
            },
            380.0,
            move || {
                field(
                    l("Name"),
                    text_field(name, SharedString::default).auto_focus(true).on_submit(move |_: &str| commit()),
                )
                .into_element()
            },
            move || {
                let label = move || {
                    tr(match named.get() {
                        Named::NewGroup | Named::NewTag => "Create",
                        Named::Group(_) | Named::Tag(_) => "Rename",
                    })
                };
                modal_actions(naming, l("Cancel"), label, move || !name.with(|n| n.trim().is_empty()), commit)
            },
        ))
        .child(view().p_2().child(row(
            Icon::Settings,
            l("Settings…"),
            || None,
            move || store.settings_open().get(),
            move || store.settings_open().set(true),
        )))
}

/// The podcast player itself: it has no picture, and lives as long as an
/// episode is loaded, whatever page shows.
fn podcast_player() -> impl IntoElement {
    let store = store();
    let player = store.podcast;
    let element = element_ref();
    // The media keys and Now Playing are the podcast's, unless a reader or
    // the video player has claimed them.
    let controls = std::rc::Rc::new(media::claim(move |command| match command {
        media::Command::Play => player.set_paused(false),
        media::Command::Pause => player.set_paused(true),
        media::Command::Toggle => player.set_paused(!player.paused()),
        media::Command::Next => player.seek_to(player.position_ms() + 30_000),
        media::Command::Previous => player.seek_to(player.position_ms() - 15_000),
        media::Command::Seek(position_ms) => player.seek_to(position_ms),
    }));
    // Told again every few seconds of playback, and at once on a change.
    let beat = computed(move || player.position_ms() / 5000);
    effect(move || {
        beat.get();
        controls.publish(player.playing().map(|playing| media::Now {
            title: playing.episode.title.clone(),
            artist: playing.show_title.to_string(),
            position_ms: untracked(|| player.position_ms()),
            duration_ms: player.duration_ms(),
            playing: !player.paused(),
            rate: player.rate(),
        }));
    });
    effect(move || {
        let (count, position_ms) = player.seek_request();
        if count > 0 {
            element.seek(position_ms as f64 / 1000.0);
        }
    });
    // A recording being read has the sound to itself.
    effect(move || {
        if store.open_job_id().is_some() || store.video_playing() {
            player.set_paused(true);
        }
    });
    video(move || player.playing().map(|playing| playing.source).unwrap_or_default())
        .element_ref(&element)
        .paused(move || player.paused())
        .rate(move || player.rate())
        .progress_interval(500.0)
        // An episode left part-way starts where it was left.
        .on_load(move |_: &VideoInfo| {
            let at = player.position_ms();
            if at > 0 {
                element.seek(at as f64 / 1000.0);
            }
        })
        .on_progress(move |progress: &VideoProgress| {
            player.report((progress.current_time * 1000.0) as i64, (progress.duration * 1000.0) as i64);
        })
        .on_end(move || player.set_paused(true))
        .absolute()
        .size(px(1.0))
        .opacity(0.0)
}

/// The player's bar under the pages: what plays, where it is, and its
/// transport.
fn mini_player() -> impl IntoElement {
    let player = store().podcast;
    let entrance = motion().entering(MotionPreset::FadeInUp);
    let dragging = signal(None::<f64>);
    on_key("space", move |_| player.set_paused(!player.paused()));
    view()
        .bind_motion(&entrance)
        .h(px(64.0))
        .flex_shrink_0()
        .flex_row()
        .items_center()
        .gap_3()
        .px(px(ui::PAGE_INSET))
        .border_t_1()
        .border_color(|| theme().border)
        .bg(|| theme().card)
        .child(
            toggle_icon_button(
                move || if player.paused() { Icon::Play } else { Icon::Pause },
                move || if player.paused() { tr("Play") } else { tr("Pause") },
                Variant::Ghost,
                Size::Md,
            )
            .on_press(move || player.set_paused(!player.paused())),
        )
        .child(
            view()
                .w(px(220.0))
                .flex_shrink(1.0)
                .min_w(px(0.0))
                .child(
                    text(move || player.playing().map(|p| SharedString::from(p.episode.title)).unwrap_or_default())
                        .text_sm()
                        .font_weight(FontWeight::MEDIUM)
                        .number_of_lines(1)
                        .text_color(|| theme().foreground),
                )
                .child(
                    text(move || player.playing().map(|p| p.show_title).unwrap_or_default())
                        .text_xs()
                        .number_of_lines(1)
                        .text_color(|| theme().muted_foreground),
                ),
        )
        .child(time_text(move || dragging.get().map_or(player.position_ms(), |ms| ms as i64)))
        .child(
            slider(
                "Position",
                move || dragging.get().unwrap_or(player.position_ms() as f64),
                move || player.duration_ms() as f64,
                move |value| dragging.set(Some(value)),
                move |value| {
                    player.seek_to(value as i64);
                    dragging.set(None);
                },
            )
            .flex_1(),
        )
        .child(time_text(move || player.duration_ms()))
        .child(rate_menu(
            Variant::Ghost,
            move || player.rate(),
            move |rate| {
                player.set_rate(rate);
                store().save_rate("podcast_rate", rate);
            },
        ))
        .child(icon_button(Icon::Close, tr("Close player"), Size::Md, move || player.stop()))
}

/// A time of playback, in figures that do not shift as they change.
pub(crate) fn time_text(ms: impl Fn() -> i64 + 'static) -> Text {
    text(move || clock(ms())).text_xs().tabular_nums().text_color(|| theme().muted_foreground)
}

/// The speed menu of a player: the speeds, the current one checked.
/// `variant` is the trigger's: [`Variant::Picture`] over a video.
pub(crate) fn rate_menu(
    variant: Variant,
    rate: impl Fn() -> f32 + Copy + 'static,
    set: impl Fn(f32) + Copy + 'static,
) -> impl IntoElement {
    menu(ui::button(variant, Size::Sm, move || rate_label(rate())).accessibility_label(tr("Playback speed"))).children(
        RATES.iter().map(move |option| {
            let option = *option;
            ui::menu_choice(rate_label(option), move || (rate() - option).abs() < 0.001, move || set(option))
        }),
    )
}

/// The band at the top of a page beside the sidebar: it drags the window,
/// and its content starts clear of nothing (the window's controls are over
/// the sidebar).
pub(crate) fn top_bar() -> View {
    let store = store();
    // Under the system's header, what is left of the bar is a row of the
    // page's own controls.
    if system_header() {
        return view().flex_shrink_0().flex_row().items_center().gap_2().px(px(ui::PAGE_INSET)).py_2();
    }
    // With the sidebar away the bar is under the window's controls: it
    // starts past them, with the button that brings the sidebar back.
    let alone = move || (store.sidebar_hidden() || platform::compact()) && !store.immersive();
    view()
        .h(px(BAR))
        .flex_shrink_0()
        .flex_row()
        .items_center()
        .gap_2()
        .style_with(move |s| {
            // The window's own controls are over this bar's ends: at the
            // left on a Mac, at the right on Windows. In full screen there
            // are none.
            let controls = title_bar();
            let left = if alone() && controls.left.0 > 0.0 { controls.left.0 + CONTROLS_GAP } else { ui::PAGE_INSET };
            let right = if controls.right.0 > 0.0 { controls.right.0 + CONTROLS_GAP } else { ui::PAGE_INSET };
            s.pl(px(left)).pr(px(right))
        })
        .child(when(alone, move || {
            view()
                .window_drag(false)
                .child(icon_button(Icon::Sidebar, tr("Show sidebar"), Size::Sm, move || store.toggle_sidebar()))
        }))
        .border_b_1()
        .border_color(|| theme().border)
        .window_drag(true)
}
