use std::{collections::HashSet, time::Duration};

use listenook_core::{
    format,
    podcast::{COLLECTIONS, Episode, Feed, ShowSummary, strip_html},
};
use nsh_base::theme;
use nsh_core::{element::Position, prelude::*};

use crate::ui::{error_text, l, tr};
use crate::work::podcasts;
use crate::{
    pages::chrome::top_bar,
    platform::file_url,
    state::store,
    ui::{
        self, Badge, Chip, Icon, IconButton, Modal, ModalActions, Size, Spinner, Status, ToggleButton, Variant, button,
        field, hint, icon, list_row, search_field_ref, section, text_field_with, toggle_icon_button,
        tokens::{self, motion},
    },
};

#[derive(Clone, Copy)]
struct Page {
    open: Signal<Option<String>>,
    feed: Signal<Option<Feed>>,
    loading: Signal<bool>,
    error: Signal<Option<&'static str>>,
}

impl Page {
    fn open_show(&self, feed_url: &str) {
        batch(|| {
            self.error.set(None);
            self.open.set(Some(feed_url.to_owned()));
        });
    }
}

impl Page {
    fn loading_shows() -> Self {
        let page = Self::idle();
        page.load();
        page
    }

    fn idle() -> Self {
        Self {
            open: crate::state::podcast::PodcastState::get().open_show(),
            feed: signal(None),
            loading: signal(false),
            error: signal(None),
        }
    }
}

pub(crate) fn show_screen() -> impl IntoElement {
    view().flex_1().child(show_page(Page::loading_shows()))
}

pub(crate) fn podcasts_page() -> impl IntoElement {
    if crate::pages::chrome::system_header() {
        let page = Page::idle();
        return view().flex_1().child(discover(page)).child(add_dialog(page));
    }
    let page = Page::loading_shows();
    view()
        .flex_1()
        .child(when(move || page.open.get().is_some(), move || show_page(page)).otherwise(move || discover(page)))
        .child(add_dialog(page))
}

impl Page {
    fn load(self) {
        let page = self;
        effect(move || {
            let Some(url) = page.open.get() else {
                return;
            };
            untracked(|| {
                batch(|| {
                    page.feed.set(crate::state::podcast::PodcastState::get().feed(&url));
                    page.loading.set(true);
                });
            });
            spawn(async move {
                match podcasts::load_feed(&url).await {
                    Ok(feed) => drop(page.feed.try_set(Some(feed))),
                    Err(code) => drop(page.error.try_set(Some(code))),
                }
                page.loading.try_set(false);
            });
        });
    }
}

fn add_dialog(page: Page) -> impl IntoElement {
    let open = crate::state::podcast::PodcastState::get().adding();
    let url = signal(String::new());
    effect(move || {
        if open.get() {
            url.set(String::new());
        }
    });
    let add = move || {
        let feed = url.get_untracked().trim().to_owned();
        if !feed.is_empty() {
            page.open_show(&feed);
            open.set(false);
        }
    };
    Modal {
        open,
        title: l("Add by URL"),
        width: 420.0,
        content: move || {
            field(
                l("RSS URL"),
                text_field_with(url, l("Paste a public RSS URL"), move |input| {
                    input.keyboard_type(KeyboardType::Url).auto_focus(true).on_submit(move |_: &str| add())
                }),
            )
            .into_element()
        },
        actions: move || {
            ModalActions {
                open,
                cancel: l("Cancel"),
                commit: l("Open"),
                enabled: move || !url.with(|u| u.trim().is_empty()),
                on_commit: add,
            }
            .into_element()
        },
    }
}

fn artwork(url: impl Fn() -> String + 'static, size: f32) -> impl IntoElement {
    view()
        .size(px(size))
        .flex_shrink_0()
        .rounded(|| tokens::corner(tokens::Corner::Medium))
        .overflow_hidden()
        .bg(|| theme().muted)
        .items_center()
        .justify_center()
        .text_color(|| theme().muted_foreground)
        .child(icon(Icon::Podcast, size * 0.4).absolute())
        .child(image(url).size(px(size)).object_fit(ResizeMode::Cover))
}

fn discover(page: Page) -> impl IntoElement {
    let query = crate::state::podcast::PodcastState::get().query;
    let results = signal(Vec::<ShowSummary>::new());
    let featured = signal(Vec::<ShowSummary>::new());
    let busy = signal(false);
    let failed = signal(None::<&'static str>);
    let searching = move || query.with(|q| q.trim().chars().count() >= 2);
    let shelf = signal(0_usize);
    let shelving = signal(true);
    effect(move || {
        let chosen = shelf.get();
        shelving.set(true);
        spawn(async move {
            let loaded = match chosen {
                0 => podcasts::featured().await,
                1 => podcasts::top_shows(None, 24).await,
                other => podcasts::top_shows(COLLECTIONS.get(other - 2).map(|(_, genre)| *genre), 24).await,
            };
            if shelf.get_untracked() != chosen {
                return;
            }
            batch(|| {
                match loaded {
                    Ok(shows) => {
                        featured.set(shows);
                        failed.set(None);
                    }
                    Err(code) => failed.set(Some(code)),
                }
                shelving.set(false);
            });
        });
    });
    effect(move || {
        let term = query.with(|q| q.trim().to_owned());
        if term.chars().count() < 2 {
            return;
        }
        busy.set(true);
        spawn(async move {
            timer(Duration::from_millis(400)).await;
            match podcasts::search(&term).await {
                Ok(shows) => batch(|| {
                    results.set(shows);
                    failed.set(None);
                }),
                Err(code) => failed.set(Some(code)),
            }
            busy.set(false);
        });
    });
    let search_input = element_ref();
    on_key("mod+f", move |_| search_input.focus());
    view()
        .flex_1()
        .child(
            top_bar()
                .child(
                    search_field_ref(query, l("Search podcasts"), &search_input)
                        .flex_1()
                        .max_w(px(420.0))
                        .window_drag(false),
                )
                .child(when(
                    || !crate::pages::chrome::system_header(),
                    move || {
                        view().flex_1().flex_row().justify_end().child(view().window_drag(false).child(IconButton {
                            glyph: Icon::Plus,
                            name: tr("Add by URL"),
                            size: Size::Sm,
                            on_press: move || {
                                crate::state::podcast::PodcastState::get()
                                    .act(crate::state::podcast::PodcastAction::AddShow)
                            },
                        }))
                    },
                )),
        )
        .child(
            scroll().flex_1().child(
                view()
                    .p(px(ui::PAGE_INSET))
                    .gap_6()
                    .child(when(
                        move || !searching() && !crate::state::podcast::PodcastState::get().followed().is_empty(),
                        move || {
                            section(
                                l("Following"),
                                card_grid().child(each(
                                    move || crate::state::podcast::PodcastState::get().followed(),
                                    |followed| followed.feed_url.clone(),
                                    move |followed, _| {
                                        let summary = computed(move || {
                                            followed.with(|f| ShowSummary {
                                                title: f.title.clone(),
                                                feed_url: f.feed_url.clone(),
                                                artwork_url: f.artwork_url.clone().unwrap_or_default(),
                                                ..ShowSummary::default()
                                            })
                                        });
                                        show_card(page, move || summary.get())
                                    },
                                )),
                            )
                        },
                    ))
                    .child(when(
                        move || failed.get().is_some(),
                        move || {
                            text(move || failed.get().map(error_text).unwrap_or_default())
                                .text_sm()
                                .text_color(|| theme().destructive)
                        },
                    ))
                    .child(
                        when(searching, move || {
                            view()
                                .gap_1()
                                .child(when(
                                    move || busy.get() && results.with(Vec::is_empty),
                                    || Spinner { size: 18.0 },
                                ))
                                .child(when(
                                    move || !busy.get() && results.with(Vec::is_empty),
                                    || hint(l("No podcasts matched that search.")),
                                ))
                                .child(each(
                                    results,
                                    |show: &ShowSummary| show.feed_url.clone(),
                                    move |show, _| show_row(page, show),
                                ))
                        })
                        .otherwise(move || {
                            let chips = move || {
                                let mut shelves: Vec<&'static str> = vec!["Worth studying", "Popular"];
                                shelves.extend(COLLECTIONS.iter().map(|(name, _)| *name));
                                view().flex_row().gap_2().children(shelves.into_iter().enumerate().map(
                                    move |(index, name)| Chip {
                                        label: l(name),
                                        selected: move || shelf.get() == index,
                                        on_press: move || shelf.set(index),
                                    },
                                ))
                            };
                            section(
                                l("Browse"),
                                when(
                                    || crate::platform::compact() || crate::platform::is_phone(),
                                    move || {
                                        scroll()
                                            .horizontal()
                                            .scrollbar(false)
                                            .mx(px(-ui::PAGE_INSET))
                                            .child(chips().px(px(ui::PAGE_INSET)))
                                    },
                                )
                                .otherwise(move || chips().flex_wrap()),
                            )
                            .child(when(
                                move || shelving.get() && featured.with(Vec::is_empty),
                                || Spinner { size: 18.0 },
                            ))
                            .child(
                                card_grid()
                                    .opacity(move || if shelving.get() { 0.5_f32 } else { 1.0 })
                                    .transition_opacity()
                                    .duration(motion::FAST)
                                    .child(each(
                                        // Shows followed are in Following, just above.
                                        move || {
                                            let podcasts = crate::state::podcast::PodcastState::get();
                                            featured.with(|shows| {
                                                shows
                                                    .iter()
                                                    .filter(|show| !podcasts.is_followed(&show.feed_url))
                                                    .cloned()
                                                    .collect::<Vec<_>>()
                                            })
                                        },
                                        |show: &ShowSummary| show.feed_url.clone(),
                                        move |show, _| show_card(page, move || show.get()),
                                    )),
                            )
                            .child(hint(l("Podcast search and artwork are provided by Apple Podcasts.")))
                        }),
                    ),
            ),
        )
}

fn show_row(page: Page, show: ReadSignal<ShowSummary>) -> impl IntoElement {
    list_row(|| false)
        .on_press(move || page.open_show(&show.get_untracked().feed_url))
        .child(artwork(move || show.with(|s| s.artwork_url.clone()), 44.0))
        .child(
            view()
                .flex_1()
                .min_w(px(0.0))
                .child(
                    text(move || show.with(|s| SharedString::from(s.title.clone())))
                        .text_sm()
                        .font_weight(FontWeight::MEDIUM)
                        .number_of_lines(1)
                        .text_color(|| theme().foreground),
                )
                .child(
                    text(move || show.with(|s| SharedString::from(s.author.clone())))
                        .text_xs()
                        .number_of_lines(1)
                        .text_color(|| theme().muted_foreground),
                ),
        )
        .child(view().text_color(|| theme().muted_foreground).child(icon(Icon::ChevronRight, 14.0)))
}

fn card_grid() -> View {
    view().grid().grid_template_columns("repeat(auto-fill, minmax(112px, 1fr))").gap_2().mx(px(-8.0))
}

fn show_card(page: Page, show: impl Fn() -> ShowSummary + Copy + 'static) -> impl IntoElement {
    ui::pressable_card()
        .on_press(move || page.open_show(&untracked(show).feed_url))
        .gap_2()
        .p_2()
        .child(
            view()
                .aspect_square()
                .rounded(|| tokens::corner(tokens::Corner::Medium))
                .overflow_hidden()
                .bg(|| theme().muted)
                .items_center()
                .justify_center()
                .text_color(|| theme().muted_foreground)
                .child(icon(Icon::Podcast, 40.0).absolute())
                .child(image(move || show().artwork_url).size_full().object_fit(ResizeMode::Cover)),
        )
        .child(
            text(move || SharedString::from(show().title))
                .text_sm()
                .font_weight(FontWeight::MEDIUM)
                .number_of_lines(2)
                .text_color(|| theme().foreground),
        )
}

fn show_page(page: Page) -> impl IntoElement {
    let feed = page.feed;
    let followed = move || {
        page.open.get().is_some_and(|url| {
            crate::state::podcast::PodcastState::get()
                .is_followed(&feed.with(|f| f.as_ref().map_or(url, |f| f.feed_url.clone())))
        })
    };
    let episodes = computed(move || feed.with(|f| f.as_ref().map(|f| f.episodes.clone()).unwrap_or_default()));
    let query = signal(String::new());
    let searchable = computed(move || {
        episodes.with(|e| {
            e.iter()
                .map(|e| format!("{}\n{}", e.title, e.description.as_deref().map(strip_html).unwrap_or_default()))
                .map(|text| text.to_lowercase())
                .collect::<Vec<_>>()
        })
    });
    let shown = computed(move || {
        let needle = query.with(|q| q.trim().to_lowercase());
        if needle.is_empty() {
            return episodes.get();
        }
        episodes.with(|e| {
            searchable.with(|texts| {
                e.iter().zip(texts).filter(|(_, text)| text.contains(&needle)).map(|(e, _)| e.clone()).collect()
            })
        })
    });
    let notes_open = signal(HashSet::<String>::new());
    let filter_input = element_ref();
    let pushed = crate::pages::chrome::system_header();
    if !pushed {
        on_key("mod+f", move |_| filter_input.focus());
    }
    let follow = move || {
        button(Variant::Default, Size::Md, move || if followed() { tr("Unfollow") } else { tr("Follow") }).on_press(
            move || {
                if let Some(feed) = feed.get_untracked() {
                    crate::state::podcast::PodcastState::get()
                        .act(crate::state::podcast::PodcastAction::SetFollowed(&feed, !untracked(followed)));
                }
            },
        )
    };
    view()
        .flex_1()
        .child(when(
            move || !pushed,
            move || {
                top_bar()
                    .child(view().window_drag(false).child(IconButton {
                        glyph: Icon::ChevronLeft,
                        name: tr("Back"),
                        size: Size::Sm,
                        on_press: move || {
                            batch(|| {
                                page.open.set(None);
                                page.feed.set(None);
                            })
                        },
                    }))
                    .child(
                        text(move || {
                            feed.with(|f| {
                                f.as_ref()
                                    .map(|f| SharedString::from(f.title.clone()))
                                    .unwrap_or_else(|| tr("Podcasts"))
                            })
                        })
                        .text_base()
                        .font_weight(FontWeight::SEMIBOLD)
                        .number_of_lines(1)
                        .flex_1()
                        .text_color(|| theme().foreground)
                        .role(AccessibilityRole::Header),
                    )
                    .child(when(move || feed.with(Option::is_some), move || view().window_drag(false).child(follow())))
            },
        ))
        .child(
            when(
                move || feed.with(Option::is_none),
                move || {
                    view().flex_1().items_center().justify_center().gap_3().child(
                        when(move || page.loading.get(), || Spinner { size: 20.0 }).otherwise(move || {
                            text(move || page.error.get().map(error_text).unwrap_or_default())
                                .text_sm()
                                .text_color(|| theme().destructive)
                        }),
                    )
                },
            )
            .otherwise(move || {
                virtual_list(move || shown.with(Vec::len), move |at| episode_row(page, shown, notes_open, at))
                    .smooth_wheel(true)
                    .keys(move || shown.with(|e| e.iter().map(|e| e.id.clone()).collect::<Vec<_>>()))
                    .estimated_item_size(px(68.0))
                    .content_padding(px(ui::PAGE_INSET - 12.0))
                    .header(
                        view()
                            .gap_4()
                            .px_3()
                            .pb_4()
                            .child(
                                view()
                                    .flex_row()
                                    .gap_4()
                                    .child(artwork(
                                        move || {
                                            feed.with(|f| {
                                                f.as_ref().and_then(|f| f.artwork_url.clone()).unwrap_or_default()
                                            })
                                        },
                                        88.0,
                                    ))
                                    .child(
                                        view()
                                            .flex_1()
                                            .min_w(px(0.0))
                                            .gap_1()
                                            .child(
                                                text(move || {
                                                    feed.with(|f| {
                                                        f.as_ref()
                                                            .and_then(|f| f.author.clone())
                                                            .map(SharedString::from)
                                                            .unwrap_or_default()
                                                    })
                                                })
                                                .text_sm()
                                                .font_weight(FontWeight::MEDIUM)
                                                .text_color(|| theme().foreground),
                                            )
                                            .child(
                                                text(move || {
                                                    feed.with(|f| {
                                                        f.as_ref()
                                                            .and_then(|f| f.description.clone())
                                                            .map(SharedString::from)
                                                            .unwrap_or_default()
                                                    })
                                                })
                                                .text_sm()
                                                .number_of_lines(3)
                                                .text_color(|| theme().muted_foreground),
                                            )
                                            .child(when(
                                                move || pushed,
                                                move || view().flex_row().pt_1().child(follow()),
                                            ))
                                            .child(when(
                                                move || page.error.get().is_some(),
                                                move || {
                                                    text(move || page.error.get().map(error_text).unwrap_or_default())
                                                        .text_xs()
                                                        .text_color(|| theme().destructive)
                                                },
                                            )),
                                    ),
                            )
                            .child(search_field_ref(query, l("Filter episodes"), &filter_input).max_w(px(420.0))),
                    )
                    .empty(when(
                        move || query.with(|q| !q.trim().is_empty()),
                        || hint(l("No episodes match that filter.")).px_3(),
                    ))
                    .flex_1()
            }),
        )
}

fn episode_row(
    page: Page,
    episodes: Memo<Vec<Episode>>,
    notes_open: Signal<HashSet<String>>,
    at: Position,
) -> impl IntoElement {
    let store = store();
    let player = crate::state::podcast::PodcastState::get();
    let episode = computed(move || episodes.with(|e| e.get(at.index()).cloned()));
    let id = move || episode.with(|e| e.as_ref().map(|e| e.id.clone()).unwrap_or_default());
    let current = move || player.is_current(&id());
    let playing = move || current() && !player.paused();
    let job = move || {
        let id = id();
        store.jobs().into_iter().find(|job| job.is_episode(&id))
    };
    let notes = computed(move || {
        episode.with(|e| e.as_ref().and_then(|e| e.description.as_deref()).map(strip_html).unwrap_or_default())
    });
    let open = move || notes_open.with(|shown| shown.contains(&id()));
    let narrow = untracked(crate::platform::compact);
    let meta = move || -> SharedString {
        let mut parts = episode.with(|e| {
            let mut parts = Vec::new();
            if let Some(published) = e.as_ref().and_then(|e| e.published_at.as_deref()) {
                parts.push(format::shown(format::Shown::Date(published)));
            }
            if let Some(duration) = e.as_ref().and_then(|e| e.duration_ms) {
                parts.push(format::shown(format::Shown::Duration(duration)));
            }
            parts
        });
        if !narrow && !open() {
            let preview: String = notes.with(|n| n.replace('\n', " ").chars().take(120).collect());
            if !preview.is_empty() {
                parts.push(preview);
            }
        }
        parts.join(" · ").into()
    };
    let toggle_play = move || {
        let Some(episode) = episode.get_untracked() else {
            return;
        };
        if player.is_current(&episode.id) {
            player.act(crate::state::podcast::PodcastAction::SetPaused(!player.paused()));
            return;
        }
        let local = untracked(job).filter(|job| std::path::Path::new(&job.source_path).exists());
        let source = local.map_or_else(|| episode.enclosure_url.clone(), |job| file_url(&job.source_path));
        let show =
            page.feed.with_untracked(|f| f.as_ref().map(|f| SharedString::from(f.title.clone())).unwrap_or_default());
        player.act(crate::state::podcast::PodcastAction::Play(episode, show, source));
    };
    let toggle_notes = move || {
        let id = untracked(id);
        notes_open.update(|shown| {
            if !shown.remove(&id) {
                shown.insert(id);
            }
        });
    };
    view()
        .gap_2()
        .px_3()
        .py_2()
        .rounded(|| tokens::corner(tokens::Corner::Medium))
        .transition_colors()
        .duration(motion::INSTANT)
        .bg(move || if current() { tokens::ink(tokens::Ink::Highlight) } else { theme().background })
        .hover(move |s| {
            s.bg(
                move || {
                    if current() { tokens::ink(tokens::Ink::Highlight) } else { tokens::ink(tokens::Ink::HoverWash) }
                },
            )
        })
        .child(
            view()
                .flex_row()
                .items_center()
                .gap_3()
                .child(
                    toggle_icon_button(
                        move || if playing() { Icon::Pause } else { Icon::Play },
                        move || if playing() { tr("Pause playback") } else { tr("Play") },
                        Variant::Default,
                        Size::Md,
                    )
                    .on_press(toggle_play),
                )
                .child(
                    nsh_base::button()
                        .on_press(toggle_play)
                        .flex_1()
                        .min_w(px(0.0))
                        .gap_0p5()
                        .rounded(|| tokens::corner(tokens::Corner::Small))
                        .child(
                            text(move || {
                                episode.with(|e| {
                                    e.as_ref().map(|e| SharedString::from(e.title.clone())).unwrap_or_default()
                                })
                            })
                            .text_sm()
                            .font_weight(FontWeight::MEDIUM)
                            .number_of_lines(if narrow { 2 } else { 1 })
                            .text_color(|| theme().foreground),
                        )
                        .child(text(meta).text_xs().number_of_lines(1).text_color(|| theme().muted_foreground)),
                )
                .child(when(
                    move || !narrow && episode.with(|e| e.as_ref().is_some_and(|e| !e.transcripts.is_empty())),
                    || Badge { label: l("Has captions"), status: || Status::Neutral },
                ))
                .child(
                    button(Variant::Outline, Size::Sm, move || match job() {
                        Some(job) if job.has_transcript() => tr("Open"),
                        Some(_) => tr("In Library"),
                        None => tr("Deep listen"),
                    })
                    .on_press(move || {
                        if let (Some(episode), Some(feed)) = (episode.get_untracked(), page.feed.get_untracked()) {
                            podcasts::deep_listen(&episode, &feed);
                        }
                    }),
                )
                .child(when(
                    move || notes.with(|n| !n.is_empty()),
                    move || ToggleButton {
                        variant: Variant::Ghost,
                        glyph: Icon::ChevronDown,
                        name: tr("Show notes"),
                        size: Size::Sm,
                        on: open,
                        on_press: toggle_notes,
                    },
                )),
        )
        .child(when(open, move || {
            text(move || SharedString::from(notes.get()))
                .text_sm()
                .text_color(|| theme().muted_foreground)
                .pl(px(Size::Md.height() + 12.0))
        }))
}
