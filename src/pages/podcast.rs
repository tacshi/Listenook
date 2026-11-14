use std::time::Duration;

use listenook_core::{
    format::{date, duration_words},
    podcast::{COLLECTIONS, Episode, Feed, ShowSummary, strip_html},
};
use nsh_base::theme;
use nsh_core::{element::Position, prelude::*};

use crate::{
    services::podcasts,
    shell::top_bar,
    state::{error_text, l, store, tr},
    ui::{
        self, Icon, Size, Status, Variant, badge, button, chip, field, hint, icon, icon_button, list_row, modal,
        modal_actions, search_field, section, spinner, text_field_with, toggle_icon_button,
        tokens::{self, motion},
    },
    util::file_url,
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
        Self { open: store().podcast.open_show, feed: signal(None), loading: signal(false), error: signal(None) }
    }
}

pub(crate) fn show_screen() -> impl IntoElement {
    view().flex_1().child(show_page(Page::loading_shows()))
}

pub(crate) fn podcasts_page() -> impl IntoElement {
    if crate::shell::system_header() {
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
        let store = store();
        let page = self;
        effect(move || {
            let Some(url) = page.open.get() else {
                return;
            };
            untracked(|| {
                batch(|| {
                    page.feed.set(store.podcast.feed(&url));
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
    let open = store().podcast.adding;
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
    modal(
        open,
        l("Add by URL"),
        420.0,
        move || {
            field(
                l("RSS URL"),
                text_field_with(url, l("Paste a public RSS URL"), move |input| {
                    input.keyboard_type(KeyboardType::Url).auto_focus(true).on_submit(move |_: &str| add())
                }),
            )
            .into_element()
        },
        move || modal_actions(open, l("Cancel"), l("Open"), move || !url.with(|u| u.trim().is_empty()), add),
    )
}

fn artwork(url: impl Fn() -> String + 'static, size: f32) -> impl IntoElement {
    view()
        .size(px(size))
        .flex_shrink_0()
        .rounded(tokens::radius)
        .overflow_hidden()
        .bg(|| theme().muted)
        .items_center()
        .justify_center()
        .text_color(|| theme().muted_foreground)
        .child(icon(Icon::Podcast, size * 0.4).absolute())
        .child(image(url).size(px(size)).object_fit(ResizeMode::Cover))
}

fn discover(page: Page) -> impl IntoElement {
    let query = store().podcast.query;
    let results = signal(Vec::<ShowSummary>::new());
    let featured = signal(Vec::<ShowSummary>::new());
    let busy = signal(false);
    let failed = signal(None::<&'static str>);
    let searching = move || query.with(|q| q.trim().chars().count() >= 2);
    let shelf = signal(0_usize);
    effect(move || {
        let chosen = shelf.get();
        spawn(async move {
            let loaded = match chosen {
                0 => podcasts::featured().await,
                1 => podcasts::top_shows(None, 24).await,
                other => podcasts::top_shows(COLLECTIONS.get(other - 2).map(|(_, genre)| *genre), 24).await,
            };
            match loaded {
                Ok(shows) => batch(|| {
                    featured.set(shows);
                    failed.set(None);
                }),
                Err(code) => failed.set(Some(code)),
            }
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
    let store = store();
    view()
        .flex_1()
        .child(
            top_bar()
                .child(search_field(query, l("Search podcasts")).flex_1().max_w(px(420.0)).window_drag(false))
                .child(when(
                    || !crate::shell::system_header(),
                    move || {
                        view().flex_1().flex_row().justify_end().child(view().window_drag(false).child(icon_button(
                            Icon::Plus,
                            tr("Add by URL"),
                            Size::Sm,
                            move || store.podcast.adding.set(true),
                        )))
                    },
                )),
        )
        .child(
            scroll().flex_1().child(
                view()
                    .p(px(ui::PAGE_INSET))
                    .gap_6()
                    .child(when(
                        move || !searching() && !store.podcast.followed().is_empty(),
                        move || {
                            section(
                                l("Following"),
                                card_grid().child(each(
                                    move || store.podcast.followed(),
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
                                .child(when(move || busy.get() && results.with(Vec::is_empty), || spinner(18.0)))
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
                                    move |(index, name)| {
                                        chip(l(name), move || shelf.get() == index, move || shelf.set(index))
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
                            .child(card_grid().child(each(
                                featured,
                                |show: &ShowSummary| show.feed_url.clone(),
                                move |show, _| show_card(page, move || show.get()),
                            )))
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
    nsh_base::button()
        .on_press(move || page.open_show(&untracked(show).feed_url))
        .gap_2()
        .p_2()
        .rounded(tokens::radius_lg)
        .transition_colors()
        .duration(motion::INSTANT)
        .hover(|s| s.bg(tokens::hover_wash))
        .active(|s| s.bg(|| theme().accent))
        .focus_visible(tokens::focus_ring)
        .child(
            view()
                .aspect_square()
                .rounded(tokens::radius)
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
    let store = store();
    let feed = page.feed;
    let followed = move || {
        page.open.get().is_some_and(|url| {
            store.podcast.is_followed(&feed.with(|f| f.as_ref().map_or(url, |f| f.feed_url.clone())))
        })
    };
    let episodes = computed(move || feed.with(|f| f.as_ref().map(|f| f.episodes.clone()).unwrap_or_default()));
    let pushed = crate::shell::system_header();
    let follow = move || {
        button(Variant::Default, Size::Md, move || if followed() { tr("Unfollow") } else { tr("Follow") }).on_press(
            move || {
                if let Some(feed) = feed.get_untracked() {
                    store.podcast.set_followed(&feed, !untracked(followed));
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
                    .child(view().window_drag(false).child(icon_button(
                        Icon::ChevronLeft,
                        tr("Back"),
                        Size::Sm,
                        move || {
                            batch(|| {
                                page.open.set(None);
                                page.feed.set(None);
                            })
                        },
                    )))
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
                        when(move || page.loading.get(), || spinner(20.0)).otherwise(move || {
                            text(move || page.error.get().map(error_text).unwrap_or_default())
                                .text_sm()
                                .text_color(|| theme().destructive)
                        }),
                    )
                },
            )
            .otherwise(move || {
                virtual_list(move || episodes.with(Vec::len), move |at| episode_row(page, episodes, at))
                    .keys(move || episodes.with(|e| e.iter().map(|e| e.id.clone()).collect::<Vec<_>>()))
                    .estimated_item_size(px(68.0))
                    .content_padding(px(ui::PAGE_INSET - 12.0))
                    .header(
                        view()
                            .flex_row()
                            .gap_4()
                            .px_3()
                            .pb_4()
                            .child(artwork(
                                move || {
                                    feed.with(|f| f.as_ref().and_then(|f| f.artwork_url.clone()).unwrap_or_default())
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
                                    .child(when(move || pushed, move || view().flex_row().pt_1().child(follow())))
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
                    .flex_1()
            }),
        )
}

fn episode_row(page: Page, episodes: Memo<Vec<Episode>>, at: Position) -> impl IntoElement {
    let store = store();
    let player = store.podcast;
    let episode = computed(move || episodes.with(|e| e.get(at.index()).cloned()));
    let id = move || episode.with(|e| e.as_ref().map(|e| e.id.clone()).unwrap_or_default());
    let playing = move || player.is_current(&id()) && !player.paused();
    let job = move || {
        let id = id();
        store.jobs().into_iter().find(|job| job.podcast_provenance.as_ref().is_some_and(|p| p.episode_id == id))
    };
    let narrow = untracked(crate::platform::compact);
    let meta = move || -> SharedString {
        episode.with(|e| {
            let Some(e) = e else {
                return SharedString::default();
            };
            let mut parts = Vec::new();
            if let Some(published) = &e.published_at {
                parts.push(date(published));
            }
            if let Some(duration) = e.duration_ms {
                parts.push(duration_words(duration));
            }
            if let Some(description) =
                e.description.as_deref().filter(|_| !narrow).map(strip_html).filter(|d| !d.is_empty())
            {
                parts.push(description.replace('\n', " ").chars().take(120).collect());
            }
            parts.join(" · ").into()
        })
    };
    view()
        .flex_row()
        .items_center()
        .gap_3()
        .px_3()
        .py_2()
        .rounded(tokens::radius)
        .transition_colors()
        .duration(motion::INSTANT)
        .bg(move || if player.is_current(&id()) { tokens::highlight() } else { theme().background })
        .hover(|s| s.bg(tokens::hover_wash))
        .child(
            toggle_icon_button(
                move || if playing() { Icon::Pause } else { Icon::Play },
                move || if playing() { "Pause".into() } else { "Play".into() },
                Variant::Default,
                Size::Md,
            )
            .on_press(move || {
                let Some(episode) = episode.get_untracked() else {
                    return;
                };
                if player.is_current(&episode.id) {
                    player.set_paused(!player.paused());
                    return;
                }
                let local = untracked(job).filter(|job| std::path::Path::new(&job.source_path).exists());
                let source = local.map_or_else(|| episode.enclosure_url.clone(), |job| file_url(&job.source_path));
                let show = page
                    .feed
                    .with_untracked(|f| f.as_ref().map(|f| SharedString::from(f.title.clone())).unwrap_or_default());
                player.play(episode, show, source);
            }),
        )
        .child(
            view()
                .flex_1()
                .min_w(px(0.0))
                .gap_0p5()
                .child(
                    text(move || {
                        episode.with(|e| e.as_ref().map(|e| SharedString::from(e.title.clone())).unwrap_or_default())
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
            || badge(l("Has captions"), || Status::Neutral),
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
}
