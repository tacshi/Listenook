use listenook_core::media::subtitles;
use listenook_core::{format::track_position, l10n::Lang};
use nsh_base::{nav_page, nav_stack, theme};
use nsh_core::{
    desktop::{MenuRole, TitleBarOptions, TitleBarStyle, WindowAttributes},
    element::desktop::{
        MenuItem, current_window, on_reopen, register_global_shortcut, set_application_menu, set_tray, tray,
        unregister_global_shortcut,
    },
    mobile::TabBarItem,
    platform::Os,
    prelude::*,
};

use crate::state::monitor::MonitorState;
use crate::ui::{l, tr};
use crate::work::sync::Phase;
use crate::work::updater;
use crate::{
    pages::{
        self,
        chrome::{BAR, rate_menu, sidebar_width, sleep_menu, system_header, time_text},
    },
    platform,
    services::media,
    state::{Filter, Place, store},
    ui::{
        self, Icon, IconButton, MenuAction, MenuDanger, Modal, ModalActions, Size, Variant, confirm_destructive, field,
        icon, icon_of, slider, text_field_with,
        tokens::{self, motion},
    },
    work::import,
};

pub(crate) const GLOBAL_PLAY_PAUSE: &str = "ctrl+alt+space";

pub(crate) fn shell() -> impl IntoElement {
    let store = store();
    let mut bar = TitleBarOptions::default();
    bar.style = TitleBarStyle::Hidden;
    bar.height = Some(px(BAR));
    let mut attributes = WindowAttributes::default();
    attributes.title_bar = Some(bar);
    current_window().set(attributes);

    spawn(async move {
        loop {
            crate::services::woken().await;
            media::pump();
            let picked = crate::services::take_picked();
            if !picked.is_empty() {
                import::import_picked(picked);
            }
        }
    });
    if cfg!(target_os = "ios") {
        set_interval(std::time::Duration::from_millis(500), move || {
            if store.focused() {
                crate::services::keep_keys();
                crate::services::keep_scroll_on_status_bar_taps();
            }
        });
    }
    let in_tray = move || platform::has_tray() && MonitorState::get().tray_enabled();
    if std::env::args().any(|argument| argument == "--background") && untracked(in_tray) {
        current_window().hide();
    }
    effect(move || crate::services::set_dock_icon(MonitorState::get().dock_visible()));
    let show_window = move || {
        store.act(crate::state::Action::SetVideoOnly(false));
        current_window().show();
        current_window().focus();
    };
    // A click on the Dock icon brings back the window the tray icon hid: nothing shows on its own.
    on_reopen(show_window);
    effect(move || {
        let stays = in_tray();
        if stays {
            let mut items = vec![MenuItem::new(tr("Open Listenook").to_string()).on_select(show_window)];
            if !MonitorState::get().config().folder_path.is_empty() {
                let watching = if MonitorState::get().config().paused { "Resume watching" } else { "Pause watching" };
                items.push(MenuItem::new(tr(watching).to_string()).on_select(move || {
                    MonitorState::get()
                        .act(crate::state::monitor::MonitorAction::SetPaused(!MonitorState::get().config().paused))
                }));
            }
            if pages::capture_offered() {
                let item = if crate::work::capture::CaptureState::get().recording() {
                    MenuItem::new(tr("Stop recording").to_string()).on_select(move || {
                        show_window();
                        crate::work::capture::CaptureState::get().act(crate::work::capture::CaptureAction::Stop);
                    })
                } else {
                    MenuItem::new(tr("Record what’s playing").to_string()).on_select(move || {
                        show_window();
                        crate::work::capture::CaptureState::get().act(crate::work::capture::CaptureAction::Record);
                    })
                };
                items.push(item);
            }
            items.push(MenuItem::new(tr("Settings…").to_string()).on_select(move || {
                show_window();
                store.settings_open().set(true);
            }));
            if updater::SELF_UPDATING {
                items.push(MenuItem::new(tr("Check for updates…").to_string()).on_select(updater::check));
            }
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
    let launched = std::time::Instant::now();
    let open_media =
        move |paths: Vec<String>| match paths.iter().find(|path| subtitles::is(path, subtitles::Kind::Video)) {
            Some(video) => {
                pages::open_video(video);
                if launched.elapsed() < std::time::Duration::from_secs(2) && !platform::is_phone() {
                    store.act(crate::state::Action::SetVideoOnly(true));
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
                import::add_media(paths);
                show_window();
            }
        };
    let open_paths = move |paths: Vec<String>| {
        if platform::is_phone() && paths.iter().any(|path| subtitles::is(path, subtitles::Kind::Media)) {
            let taken = import::import_opened(paths);
            if taken > 0 {
                store.act(crate::state::Action::Go(Place::Library));
                ui::toast(ui::Tone::Success, tr("Added to your library"));
            } else {
                ui::toast(ui::Tone::Error, tr("That file could not be added."));
            }
            return;
        }
        open_media(paths)
    };
    if let Some(video) = std::env::args()
        .nth(1)
        .filter(|path| subtitles::is(path, subtitles::Kind::Video) && std::path::Path::new(path).is_file())
    {
        open_paths(vec![video]);
    }
    spawn(async move {
        loop {
            let files = next_open_files().await;
            open_paths(files.iter().filter_map(|path| path.to_str().map(str::to_owned)).collect());
        }
    });
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
    current_window().on_focus_change(move |focused| store.act(crate::state::Action::SetFocused(focused)));
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

    set_interval(std::time::Duration::from_secs(5), import::take_from_watched_folder);
    set_interval(std::time::Duration::from_secs(1), move || {
        crate::state::activity::ActivityState::get().act(crate::state::activity::ActivityAction::Tick)
    });
    let owner = Owner::current();
    let ticker = stored(None::<Spawned<()>>);
    let busy = computed(move || crate::work::sync::SyncState::get().busy());
    let visible = computed(move || store.sync_visible());
    effect(move || {
        let (busy, visible) = (busy.get(), visible.get());
        let next = untracked(|| {
            owner.run(|| match (busy, visible) {
                (true, _) => Some(set_interval(std::time::Duration::from_millis(250), move || {
                    crate::work::sync::SyncState::get().act(crate::work::sync::SyncAction::Tick)
                })),
                (false, true) => Some(spawn(async move {
                    while untracked(|| store.sync_visible()) {
                        let (within, seen) = untracked(|| crate::work::sync::SyncState::get().waiting());
                        let _ = blocking(move || crate::services::sync::wait(within, seen)).await;
                        crate::work::sync::SyncState::get().act(crate::work::sync::SyncAction::Tick);
                    }
                })),
                (false, false) => None,
            })
        });
        if let Some(previous) = ticker.replace(next) {
            previous.cancel();
        }
        untracked(|| crate::work::sync::SyncState::get().act(crate::work::sync::SyncAction::Tick));
    });
    effect(move || {
        let now = lifecycle();
        untracked(|| {
            if now == nsh_core::element::Lifecycle::Background {
                crate::state::activity::ActivityState::get().act(crate::state::activity::ActivityAction::Flush);
            }
            crate::work::sync::SyncState::get().act(crate::work::sync::SyncAction::Lifecycle(now));
        });
    });
    nsh_core::element::desktop::on_app_quit(move || {
        crate::state::activity::ActivityState::get().act(crate::state::activity::ActivityAction::Flush);
        crate::work::capture::CaptureState::get().act(crate::work::capture::CaptureAction::FinishOnQuit);
        async {}
    });
    updater::watch();
    if is_desktop() {
        effect(move || {
            store.lang();
            crate::work::capture::CaptureState::get().recording();
            set_application_menu(application_menu());
        });
    } else {
        on_key("mod+1", move |_| store.act(crate::state::Action::Go(Place::Home)));
        on_key("mod+2", move |_| store.act(crate::state::Action::Show(Filter::All)));
        on_key("mod+3", move |_| store.act(crate::state::Action::Go(Place::Podcasts)));
        on_key("mod+,", move |_| store.settings_open().set(true));
        on_key("mod+o", |_| import::pick_media());
        on_key("mod+b", move |_| store.act(crate::state::Action::ToggleSidebar));
        on_key("mod+shift+o", |_| pages::pick_video());
    }
    effect(move || {
        let _ = (store.place(), store.filter(), store.open_job_id());
        untracked(|| store.act(crate::state::Action::SetDrawer(false)));
    });
    let lang = computed(move || store.lang());
    let shown_in = std::cell::Cell::new(untracked(|| store.lang()));
    view()
        .flex_1()
        .flex_row()
        .on_file_drop(|event: &FileDropEvent| {
            import::add_media(event.uris.iter().map(|uri| platform::path_of_url(uri)).collect());
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
                        let translated = shown_in.replace(lang.get()) != lang.get();
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
                        crate::state::podcast::PodcastState::get().playing().is_some()
                            && store.open_job_id().is_none()
                            && store.open_video_path().is_none()
                    },
                    mini_player,
                ))
                .child(when(tab_bar_shown, tab_bar)),
        )
        .child(when(move || crate::state::podcast::PodcastState::get().playing().is_some(), podcast_player))
        .child(when(
            move || platform::compact() && store.drawer() && !store.immersive(),
            move || {
                on_key("escape", move |_| store.act(crate::state::Action::SetDrawer(false)));
                view().absolute().inset_0().flex_row().child(sidebar()).child(
                    view()
                        .flex_1()
                        .bg(|| ui::tokens::ink(ui::tokens::Ink::Scrim))
                        .on_press(move || store.act(crate::state::Action::SetDrawer(false))),
                )
            },
        ))
        .child(pages::settings_dialog())
        .child(pages::subtitle_choice_dialog())
        .child(pages::sync_dialog())
        .child(pages::sync_code_dialog())
        .child(pages::capture_dialog())
}

#[derive(Debug, Clone, PartialEq)]
enum Pushed {
    Show(String),
    Reader(String),
    Video(String),
}

fn stacked(lang: Memo<Lang>) -> impl IntoElement {
    let store = store();
    let pushed = computed(move || {
        let lang = lang.get();
        let mut pages = Vec::new();
        if let Some(show) =
            crate::state::podcast::PodcastState::get().open_show().get().filter(|_| store.place() == Place::Podcasts)
        {
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
    on_back_press(move || {
        let open = store.drawer_now();
        if open {
            store.act(crate::state::Action::SetDrawer(false));
        }
        open
    });
    let colors = |s: nsh_core::element::StyleRefinement| {
        s.bg(|| theme().background).text_color(|| theme().foreground).tint_color(|| theme().primary)
    };
    nav_stack()
        .flex_1()
        .child(
            nav_page()
                .title(move || {
                    tr(match store.place() {
                        Place::Home => "Home",
                        Place::Library => "Library",
                        Place::Podcasts => "Podcasts",
                    })
                })
                .header_style_with(colors)
                .header_left_symbol("sidebar.left")
                .header_left(ui::HeaderButton {
                    glyph: Icon::Sidebar,
                    name: tr("Sidebar"),
                    on_press: move || store.act(crate::state::Action::ToggleSidebar),
                })
                .header_right_symbol(move || SharedString::from(if store.place() == Place::Home { "" } else { "plus" }))
                .header_right(view().child(dynamic(move || {
                    match store.place() {
                        Place::Home => view()
                            .flex_row()
                            .gap_2()
                            .child(ui::HeaderButton {
                                glyph: Icon::Search,
                                name: tr("Search"),
                                on_press: move || store.home_search().set(true),
                            })
                            .child(ui::HeaderButton {
                                glyph: Icon::Plus,
                                name: tr("Add media"),
                                on_press: import::pick_media,
                            })
                            .into_element(),
                        Place::Library => {
                            ui::HeaderButton { glyph: Icon::Plus, name: tr("Add media"), on_press: import::pick_media }
                                .into_element()
                        }
                        Place::Podcasts => ui::HeaderButton {
                            glyph: Icon::Plus,
                            name: tr("Add by URL"),
                            on_press: move || {
                                crate::state::podcast::PodcastState::get()
                                    .act(crate::state::podcast::PodcastAction::AddShow)
                            },
                        }
                        .into_element(),
                    }
                })))
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
                let screen = nav_page()
                    .status_bar(move || StatusBarSetting::default().hidden(store.immersive()))
                    .hides_bottom_bar_when_pushed(true)
                    .pop_on_swipe(platform::compact)
                    .bg(|| theme().background);
                let screen = if untracked(platform::compact) {
                    screen
                } else {
                    screen.header_left_symbol("sidebar.left").header_left(ui::HeaderButton {
                        glyph: Icon::Sidebar,
                        name: tr("Sidebar"),
                        on_press: move || store.act(crate::state::Action::ToggleSidebar),
                    })
                };
                match page.get_untracked().1 {
                    Pushed::Show(url) => screen
                        .hides_bottom_bar_when_pushed(false)
                        .title(move || {
                            crate::state::podcast::PodcastState::get()
                                .feed(&url)
                                .map(|feed| SharedString::from(feed.title))
                                .unwrap_or_default()
                        })
                        .header_style_with(colors)
                        .child(pages::podcast_show())
                        .on_dismiss(move || {
                            crate::state::podcast::PodcastState::get()
                                .act(crate::state::podcast::PodcastAction::CloseShow)
                        }),
                    Pushed::Reader(id) => {
                        let job = id.clone();
                        screen
                            .title(move || {
                                store.job(&job).map(|job| SharedString::from(job.title())).unwrap_or_default()
                            })
                            .header_visible(false)
                            .child(below_status_bar(pages::reader(&id)))
                            .on_dismiss(move || store.act(crate::state::Action::CloseReader))
                    }
                    Pushed::Video(path) => screen
                        .header_visible(false)
                        .child(below_status_bar(pages::player(&path)).bg(move || {
                            if store.immersive() { ui::tokens::ink(ui::tokens::Ink::Stage) } else { theme().background }
                        }))
                        .on_dismiss(move || store.act(crate::state::Action::CloseVideo)),
                }
            },
        ))
}

pub(crate) fn stack_reaches_top() -> bool {
    cfg!(target_os = "ios")
}

fn below_status_bar(page: impl IntoElement) -> View {
    let view = view().flex_1().child(page);
    if stack_reaches_top() { view.style_when(|| !store().immersive(), |s| s.pt_safe_area()) } else { view }
}

pub(crate) fn tab_bar_shown() -> bool {
    let store = store();
    platform::is_phone()
        && platform::compact()
        && store.open_job_id().is_none()
        && store.open_video_path().is_none()
        && !store.immersive()
}

fn tab_bar() -> impl IntoElement {
    let store = store();
    let symbol = |ios: &'static str, android: &'static str| if os() == Os::Ios { ios } else { android };
    nsh_core::mobile::tab_bar()
        .items(move || {
            vec![
                TabBarItem::new(tr("Home")).icon(symbol("house", "android:ic_menu_compass")),
                TabBarItem::new(tr("Library")).icon(symbol("books.vertical", "android:ic_menu_agenda")),
                TabBarItem::new(tr("Podcasts"))
                    .icon(symbol("antenna.radiowaves.left.and.right", "android:ic_menu_slideshow")),
                TabBarItem::new(tr("Settings")).icon(symbol("gearshape", "android:ic_menu_preferences")),
            ]
        })
        .selected_index(move || {
            if store.settings_open().get() {
                3_u32
            } else {
                match store.place() {
                    Place::Home => 0,
                    Place::Library => 1,
                    Place::Podcasts => 2,
                }
            }
        })
        .on_change(move |index: &u32| match index {
            0 => store.act(crate::state::Action::Go(Place::Home)),
            1 => store.act(crate::state::Action::Show(Filter::All)),
            2 => store.act(crate::state::Action::Go(Place::Podcasts)),
            _ => store.settings_open().set(true),
        })
}

fn application_menu() -> Vec<MenuItem> {
    let store = store();
    let named = |label: &'static str| tr(label).to_string();
    let role = |role: MenuRole, label: &'static str| MenuItem::role(role).label(named(label));
    let settings =
        MenuItem::new(named("Settings…")).shortcut("mod+,").on_select(move || store.settings_open().set(true));
    let updates = MenuItem::new(named("Check for updates…")).on_select(updater::check);
    let mut menus = Vec::new();
    let mac = os() == Os::MacOs;
    if mac {
        menus.push(MenuItem::submenu(
            "Listenook",
            [
                role(MenuRole::About, "About Listenook"),
                updates.clone(),
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
        MenuItem::new(named("Add media…")).shortcut("mod+o").on_select(import::pick_media),
        MenuItem::new(named("Open video…")).shortcut("mod+shift+o").on_select(pages::pick_video),
    ];
    if pages::capture_offered() {
        file.push(if untracked(|| crate::work::capture::CaptureState::get().recording()) {
            MenuItem::new(named("Stop recording")).shortcut("mod+shift+r").on_select(move || {
                crate::work::capture::CaptureState::get().act(crate::work::capture::CaptureAction::Stop)
            })
        } else {
            MenuItem::new(named("Record what’s playing")).shortcut("mod+shift+r").on_select(move || {
                crate::work::capture::CaptureState::get().act(crate::work::capture::CaptureAction::Record)
            })
        });
    }
    file.extend([MenuItem::separator(), role(MenuRole::Close, "Close Window")]);
    if !mac {
        file.extend([
            MenuItem::separator(),
            settings,
            updates,
            MenuItem::separator(),
            role(MenuRole::Quit, "Quit Listenook"),
        ]);
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
            MenuItem::new(named("Home"))
                .shortcut("mod+1")
                .on_select(move || store.act(crate::state::Action::Go(Place::Home))),
            MenuItem::new(named("Library"))
                .shortcut("mod+2")
                .on_select(move || store.act(crate::state::Action::Show(Filter::All))),
            MenuItem::new(named("Podcasts"))
                .shortcut("mod+3")
                .on_select(move || store.act(crate::state::Action::Go(Place::Podcasts))),
            MenuItem::separator(),
            MenuItem::new(named("Show or Hide Sidebar"))
                .shortcut("mod+b")
                .on_select(move || store.act(crate::state::Action::ToggleSidebar)),
            role(MenuRole::ToggleFullScreen, "Enter or Leave Full Screen"),
        ],
    ));
    let zoom = if mac { "Zoom" } else { "Maximize" };
    menus.push(MenuItem::submenu(named("Window"), [role(MenuRole::Minimize, "Minimize"), role(MenuRole::Zoom, zoom)]));
    menus
}

fn page(open: Option<String>, place: Place, enters: bool) -> AnyElement {
    let content = match (open, place) {
        (Some(id), _) => pages::reader(&id).into_element(),
        (None, Place::Home) => pages::home().into_element(),
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

#[derive(Debug, Clone, PartialEq)]
enum Named {
    NewGroup,
    Group(String),
    NewTag,
    Tag(String),
}

const TOUCH_ROW: f32 = 44.0;

fn trailing_size() -> Size {
    if platform::is_phone() { Size::Md } else { Size::Sm }
}

fn more(name: &'static str) -> ui::Menu {
    let open = signal(false);
    ui::menu_with(open, ui::menu_trigger(Icon::More, tr(name), trailing_size(), open))
}

fn trailing_lane() -> View {
    view().w(px(trailing_size().height())).flex_shrink_0()
}

fn row(
    glyph: Icon,
    label: impl Fn() -> SharedString + 'static,
    count: impl Fn() -> Option<usize> + Clone + 'static,
    selected: impl Fn() -> bool + Clone + 'static,
    on_press: impl Fn() + 'static,
) -> nsh_base::ButtonElement {
    let (chosen, counted) = (selected.clone(), count.clone());
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
        .rounded(|| tokens::corner(tokens::Corner::Medium))
        .transition_colors()
        .duration(motion::INSTANT)
        .hover(|s| s.bg(|| tokens::ink(tokens::Ink::HoverWash)))
        .active(|s| s.bg(|| theme().input))
        .selected_style(|s| s.bg(|| theme().sidebar_accent))
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
        .child(IconButton { glyph: Icon::Plus, name: tr(add), size: trailing_size(), on_press: on_add })
}

fn sync_status() -> SharedString {
    let sync = crate::work::sync::SyncState::get();
    match sync.phase() {
        Phase::Asking(_) | Phase::Running(_) | Phase::Serving(_) => tr("Syncing…"),
        Phase::Pairing(_) => tr("Pairing…"),
        _ if sync.rounding() => tr("Syncing…"),
        Phase::Done(..) => tr("Synced"),
        Phase::Failed(_) => tr("Not synced"),
        Phase::Choosing => SharedString::default(),
    }
}

fn sidebar_title() -> View {
    let tablet = window().width.0.min(window().height.0) >= TABLET_MIN_SIDE;
    view().h(px(if tablet { 50.0 } else { 44.0 })).mb_1().flex_row().items_center().px(px(20.0)).child(
        text("Listenook")
            .text_xl()
            .font_weight(FontWeight::BOLD)
            .text_color(|| theme().foreground)
            .role(AccessibilityRole::Header),
    )
}

const TABLET_MIN_SIDE: f32 = 700.0;

fn sidebar() -> impl IntoElement {
    let store = store();
    let in_library = move |filter: Filter| store.place() == Place::Library && store.filter() == filter;
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
            Named::Group(id) => store.act(crate::state::Action::RenameGroup(&id, &text)),
            Named::NewTag => drop(store.add_tag(&text)),
            Named::Tag(id) => store.act(crate::state::Action::RenameTag(&id, &text)),
        }
        naming.set(false);
    };
    view()
        .w(px(sidebar_width()))
        .flex_shrink_0()
        .macos_backdrop(Some(tokens::sidebar_material()))
        .bg(|| if os() == Os::MacOs { theme().sidebar.opacity(0.0) } else { theme().sidebar })
        .border_r_1()
        .border_color(|| theme().sidebar_border)
        .style_when(stack_reaches_top, |s| s.pt_safe_area())
        .child(if system_header() {
            sidebar_title()
        } else {
            view().h(px(BAR)).flex_row().items_center().justify_end().px_2().window_drag(true).child(
                view().window_drag(false).child(IconButton {
                    glyph: Icon::Sidebar,
                    name: tr("Hide sidebar"),
                    size: Size::Sm,
                    on_press: move || store.act(crate::state::Action::ToggleSidebar),
                }),
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
                                    Icon::Home,
                                    l("Home"),
                                    || None,
                                    move || store.place() == Place::Home && store.open_job_id().is_none(),
                                    move || store.act(crate::state::Action::Go(Place::Home)),
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
                                    Icon::Library,
                                    l("Library"),
                                    move || Some(store.count(&Filter::All)),
                                    move || in_library(Filter::All),
                                    move || store.act(crate::state::Action::Show(Filter::All)),
                                )
                                .flex_1(),
                            )
                            .child(trailing_lane()),
                    )
                    .child(when(
                        move || store.count(&Filter::InProgress) > 0 || in_library(Filter::InProgress),
                        move || {
                            view()
                                .flex_row()
                                .items_center()
                                .child(
                                    row(
                                        Icon::Transcribe,
                                        l("In progress"),
                                        move || Some(store.count(&Filter::InProgress)),
                                        move || in_library(Filter::InProgress),
                                        move || store.act(crate::state::Action::Show(Filter::InProgress)),
                                    )
                                    .flex_1(),
                                )
                                .child(trailing_lane())
                        },
                    ))
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
                                    move || store.act(crate::state::Action::Go(Place::Podcasts)),
                                )
                                .flex_1(),
                            )
                            .child(trailing_lane()),
                    )
                    .child(heading("Groups", "New group", move || ask(Named::NewGroup, String::new())))
                    .child(each(
                        move || store.groups(),
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
                                        move || store.act(crate::state::Action::Show(shown.clone())),
                                    )
                                    .flex_1(),
                                )
                                .child(
                                    more("Group actions")
                                        .child(MenuAction {
                                            glyph: Icon::Pencil,
                                            label: l("Rename…"),
                                            on_select: {
                                                let id = deleted.clone();
                                                move || ask(Named::Group(id.clone()), group.get_untracked().name)
                                            },
                                        })
                                        .child(MenuDanger {
                                            glyph: Icon::Trash,
                                            label: l("Delete group…"),
                                            on_select: move || {
                                                let id = deleted.clone();
                                                confirm_destructive(
                                                    format!("{} “{}”?", tr("Delete group"), group.get_untracked().name),
                                                    tr("Its recordings stay in the Library."),
                                                    tr("Cancel"),
                                                    tr("Delete"),
                                                    move || store.act(crate::state::Action::DeleteGroup(&id)),
                                                );
                                            },
                                        }),
                                )
                        },
                    ))
                    .child(heading("Tags", "New tag", move || ask(Named::NewTag, String::new())))
                    .child(each(
                        move || store.tags(),
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
                                        move || store.act(crate::state::Action::Show(shown.clone())),
                                    )
                                    .flex_1(),
                                )
                                .child(
                                    more("Tag actions")
                                        .child(MenuAction {
                                            glyph: Icon::Pencil,
                                            label: l("Rename…"),
                                            on_select: move || {
                                                let tag = tag.get_untracked();
                                                ask(Named::Tag(tag.id), tag.name);
                                            },
                                        })
                                        .child(MenuDanger {
                                            glyph: Icon::Trash,
                                            label: l("Delete tag…"),
                                            on_select: move || {
                                                let id = deleted.clone();
                                                confirm_destructive(
                                                    format!("{} “{}”?", tr("Delete tag"), tag.get_untracked().name),
                                                    tr("It is taken off its recordings, which stay in the Library."),
                                                    tr("Cancel"),
                                                    tr("Delete"),
                                                    move || store.act(crate::state::Action::DeleteTag(&id)),
                                                );
                                            },
                                        }),
                                )
                        },
                    )),
            ),
        )
        .child(Modal {
            open: naming,
            title: move || {
                tr(match named.get() {
                    Named::NewGroup => "New group",
                    Named::Group(_) => "Rename group",
                    Named::NewTag => "New tag",
                    Named::Tag(_) => "Rename tag",
                })
            },
            width: 380.0,
            content: move || {
                field(
                    l("Name"),
                    text_field_with(name, SharedString::default, move |input| {
                        input.auto_focus(true).on_submit(move |_: &str| commit())
                    }),
                )
                .into_element()
            },
            actions: move || {
                let label = move || {
                    tr(match named.get() {
                        Named::NewGroup | Named::NewTag => "Create",
                        Named::Group(_) | Named::Tag(_) => "Rename",
                    })
                };
                ModalActions {
                    open: naming,
                    cancel: l("Cancel"),
                    commit: label,
                    enabled: move || !name.with(|n| n.trim().is_empty()),
                    on_commit: commit,
                }
                .into_element()
            },
        })
        .child(
            view()
                .p_2()
                .gap(px(2.0))
                .child(when(
                    move || crate::work::capture::CaptureState::get().pending(),
                    move || {
                        row(
                            Icon::Record,
                            l("Recording"),
                            || None,
                            move || crate::work::capture::CaptureState::get().is_open(),
                            move || {
                                crate::work::capture::CaptureState::get()
                                    .act(crate::work::capture::CaptureAction::Reopen)
                            },
                        )
                        .child(when(
                            move || crate::work::capture::CaptureState::get().recording(),
                            move || ui::RecordingDot {
                                live: move || !crate::work::capture::CaptureState::get().paused(),
                                side: 8.0,
                            },
                        ))
                        .child(
                            text(pages::capture_status)
                                .text_xs()
                                .tabular_nums()
                                .number_of_lines(1)
                                .text_color(|| theme().muted_foreground),
                        )
                    },
                ))
                .child(
                    row(
                        Icon::Devices,
                        l("Sync"),
                        || None,
                        move || crate::work::sync::SyncState::get().is_shown(),
                        move || crate::work::sync::SyncState::get().act(crate::work::sync::SyncAction::Show),
                    )
                    .child(text(sync_status).text_xs().number_of_lines(1).text_color(|| theme().muted_foreground)),
                )
                .child(row(
                    Icon::Settings,
                    l("Settings"),
                    || None,
                    move || store.settings_open().get(),
                    move || store.settings_open().set(true),
                )),
        )
}

fn podcast_player() -> impl IntoElement {
    let store = store();
    let player = crate::state::podcast::PodcastState::get();
    let element = element_ref();
    let controls = std::rc::Rc::new(media::claim(move |command| match command {
        media::Command::Play => player.act(crate::state::podcast::PodcastAction::SetPaused(false)),
        media::Command::Pause => player.act(crate::state::podcast::PodcastAction::SetPaused(true)),
        media::Command::Toggle => player.act(crate::state::podcast::PodcastAction::SetPaused(!player.paused())),
        media::Command::Next => player.act(crate::state::podcast::PodcastAction::SeekTo(player.position_ms() + 30_000)),
        media::Command::Previous => {
            player.act(crate::state::podcast::PodcastAction::SeekTo(player.position_ms() - 15_000))
        }
        media::Command::Seek(position_ms) => player.act(crate::state::podcast::PodcastAction::SeekTo(position_ms)),
    }));
    let sleeps = untracked(|| crate::state::sleep::SleepState::get().stops());
    effect(move || {
        if crate::state::sleep::SleepState::get().stops() != sleeps {
            untracked(|| player.act(crate::state::podcast::PodcastAction::SetPaused(true)));
        }
    });
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
    effect(move || {
        if store.open_job_id().is_some() || store.video_playing() {
            player.act(crate::state::podcast::PodcastAction::SetPaused(true));
        }
    });
    video(move || player.playing().map(|playing| playing.source).unwrap_or_default())
        .element_ref(&element)
        .paused(move || player.paused())
        .rate(move || player.rate())
        .audio_session(|| nsh_core::AudioSession::Playback)
        .progress_interval(500.0)
        .on_load(move |_: &VideoInfo| {
            let at = player.position_ms();
            if at > 0 {
                element.seek(at as f64 / 1000.0);
            }
        })
        .on_progress(move |progress: &VideoProgress| {
            player.act(crate::state::podcast::PodcastAction::Report(
                (progress.current_time * 1000.0) as i64,
                (progress.duration * 1000.0) as i64,
            ));
            if !untracked(|| player.paused()) {
                crate::state::activity::ActivityState::get()
                    .act(crate::state::activity::ActivityAction::Note(listenook_core::activity::Kind::Listen));
                crate::state::sleep::SleepState::get().act(crate::state::sleep::SleepAction::Heard);
            }
        })
        .on_end(move || {
            crate::state::sleep::SleepState::get().ended();
            player.act(crate::state::podcast::PodcastAction::SetPaused(true));
        })
        .absolute()
        .size(px(1.0))
        .opacity(0.0)
}

fn mini_player() -> impl IntoElement {
    let store = store();
    let player = crate::state::podcast::PodcastState::get();
    let entrance = motion().entering(MotionPreset::FadeInUp);
    let dragging = signal(None::<f64>);
    let on_track = computed(move || track_position(player.position_ms(), player.duration_ms()));
    let second = computed(move || player.position_ms() / 1000 * 1000);
    on_key_with("space", KeyOptions { for_focus: true, ..KeyOptions::default() }, move |_| {
        player.act(crate::state::podcast::PodcastAction::SetPaused(!player.paused()))
    });
    let track_slider = move || {
        slider(
            tr("Position"),
            move || dragging.get().unwrap_or_else(|| on_track.get() as f64),
            move || player.duration_ms() as f64,
            move |value| dragging.set(Some(value)),
            move |value| {
                player.act(crate::state::podcast::PodcastAction::SeekTo(value as i64));
                dragging.set(None);
            },
        )
        .flex_1()
    };
    let open_show = move || {
        if let Some(playing) = player.playing()
            && let Some(feed_url) = player.feed_url_of(&playing.episode.id)
        {
            store.act(crate::state::Action::Go(Place::Podcasts));
            player.act(crate::state::podcast::PodcastAction::Show(&feed_url));
        }
    };
    view()
        .bind_motion(&entrance)
        .flex_shrink_0()
        .border_t_1()
        .border_color(|| theme().border)
        .bg(|| theme().card)
        .child(when(platform::compact, move || {
            view()
                .flex_row()
                .items_center()
                .gap_2()
                .px(px(ui::PAGE_INSET))
                .pt_2()
                .child(time_text(move || dragging.get().map_or_else(|| second.get(), |ms| ms as i64)))
                .child(track_slider())
                .child(time_text(move || player.duration_ms()))
        }))
        .child(
            view()
                .h(px(64.0))
                .flex_row()
                .items_center()
                .gap_3()
                .px(px(ui::PAGE_INSET))
                .child(artwork_toggle())
                .child(when(
                    || !platform::compact(),
                    move || {
                        view()
                            .flex_row()
                            .items_center()
                            .gap_1()
                            .child(IconButton {
                                glyph: Icon::SkipBack,
                                name: tr("Back 15 seconds"),
                                size: Size::Sm,
                                on_press: move || {
                                    player.act(crate::state::podcast::PodcastAction::SeekTo(
                                        player.position_ms() - 15_000,
                                    ))
                                },
                            })
                            .child(IconButton {
                                glyph: Icon::SkipForward,
                                name: tr("Forward 30 seconds"),
                                size: Size::Sm,
                                on_press: move || {
                                    player.act(crate::state::podcast::PodcastAction::SeekTo(
                                        player.position_ms() + 30_000,
                                    ))
                                },
                            })
                    },
                ))
                .child(
                    nsh_base::button()
                        .accessibility_label(tr("Open show"))
                        .on_press(open_show)
                        .w(px(220.0))
                        .flex_shrink(1.0)
                        .min_w(px(0.0))
                        .py_1()
                        .px_1p5()
                        .mx(px(-6.0))
                        .rounded(|| tokens::corner(tokens::Corner::Medium))
                        .transition_colors()
                        .duration(motion::INSTANT)
                        .hover(|s| s.bg(|| tokens::ink(tokens::Ink::HoverWash)))
                        .active(|s| s.bg(|| theme().accent))
                        .style_when(platform::compact, |s| s.flex_grow(1.0))
                        .child(
                            text(move || {
                                player.playing().map(|p| SharedString::from(p.episode.title)).unwrap_or_default()
                            })
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
                .child(when(
                    || !platform::compact(),
                    move || {
                        view()
                            .flex_1()
                            .flex_row()
                            .items_center()
                            .gap_3()
                            .child(time_text(move || dragging.get().map_or_else(|| second.get(), |ms| ms as i64)))
                            .child(track_slider())
                            .child(time_text(move || player.duration_ms()))
                    },
                ))
                .child(rate_menu(
                    Variant::Ghost,
                    move || player.rate(),
                    move |rate| {
                        player.act(crate::state::podcast::PodcastAction::SetRate(rate));
                        store.act(crate::state::Action::SaveRate("podcast_rate", rate));
                    },
                ))
                .child(sleep_menu(Variant::Ghost, "When the episode ends"))
                .child(IconButton {
                    glyph: Icon::Close,
                    name: tr("Close player"),
                    size: Size::Md,
                    on_press: move || player.act(crate::state::podcast::PodcastAction::Stop),
                }),
        )
}

fn artwork_toggle() -> impl IntoElement {
    const SIZE: f32 = 44.0;
    let player = crate::state::podcast::PodcastState::get();
    let artwork = computed(move || player.playing().map(|p| p.artwork).unwrap_or_default());
    let scrim = move || if artwork.with(String::is_empty) { 0.0 } else { 0.35 };
    nsh_base::button()
        .accessibility_label(move || Some(if player.paused() { tr("Play") } else { tr("Pause playback") }))
        .on_press(move || player.act(crate::state::podcast::PodcastAction::SetPaused(!player.paused())))
        .size(px(SIZE))
        .flex_shrink_0()
        .rounded(|| tokens::corner(tokens::Corner::Medium))
        .overflow_hidden()
        .items_center()
        .justify_center()
        .bg(|| theme().muted)
        .child(image(move || artwork.get()).absolute().inset_0().size(px(SIZE)).object_fit(ResizeMode::Cover))
        .child(
            view()
                .absolute()
                .inset_0()
                .transition_colors()
                .duration(motion::INSTANT)
                .bg(move || theme().background.dark.opacity(scrim()))
                .hover(move |s| s.bg(move || theme().background.dark.opacity(scrim() + 0.15))),
        )
        .text_color(
            move || if artwork.with(String::is_empty) { theme().foreground } else { theme().foreground.dark.into() },
        )
        .child(icon_of(move || if player.paused() { Icon::Play } else { Icon::Pause }, 20.0))
}
