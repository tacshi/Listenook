use std::rc::Rc;

use listenook_core::{
    Job,
    format::{clock, date, duration_words},
    iso_from_millis,
    podcast::Episode,
};
use nsh_base::theme;
use nsh_core::prelude::*;

use super::{
    home_stats,
    library::{detail, kind_icon},
};
use crate::{
    platform,
    services::{artwork, podcasts, transcribe},
    shell::{page_narrow, system_header, top_bar},
    state::{Filter, Place, Shelf, l, store, tr},
    ui::{
        self, Icon, Size, Tone, Variant, card, empty_state, focused_search_field, icon, icon_text_button, list_row,
        progress_bar, toast_with_action, toggle_icon_button, tokens,
    },
    util::{self, file_url},
};

const CONTINUED: usize = 3;
const RECENT: usize = 6;
const NEW_EPISODES: usize = 4;
const NEW_FOR_DAYS: i64 = 14;
const FEED_STALE_MS: i64 = 60 * 60 * 1000;

#[derive(Debug, Clone, PartialEq)]
enum Art {
    Url(String),
    File(artwork::File),
}

impl Art {
    fn get(&self) -> String {
        match self {
            Art::Url(url) => url.clone(),
            Art::File(file) => file.cover(),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
enum Resume {
    Recording {
        id: String,
        title: String,
        glyph: Icon,
        show: Option<String>,
        artwork: Art,
        position: i64,
        duration: i64,
        at: String,
    },
    Episode {
        episode: Box<Episode>,
        show: String,
        artwork: String,
        position: i64,
        duration: i64,
        at: String,
    },
}

impl Resume {
    fn id(&self) -> &str {
        match self {
            Resume::Recording { id, .. } => id,
            Resume::Episode { episode, .. } => &episode.id,
        }
    }

    fn at(&self) -> &str {
        match self {
            Resume::Recording { at, .. } | Resume::Episode { at, .. } => at,
        }
    }

    fn title(&self) -> String {
        match self {
            Resume::Recording { title, .. } => title.clone(),
            Resume::Episode { episode, .. } => episode.title.clone(),
        }
    }

    fn progress(&self) -> (i64, i64) {
        match self {
            Resume::Recording { position, duration, .. } | Resume::Episode { position, duration, .. } => {
                (*position, *duration)
            }
        }
    }

    fn fraction(&self) -> Option<f32> {
        let (position, duration) = self.progress();
        (duration > 0).then(|| (position as f32 / duration as f32).clamp(0.0, 1.0))
    }

    fn meta(&self) -> String {
        let (position, duration) = self.progress();
        let mut parts =
            vec![if duration > 0 { format!("{} / {}", clock(position), clock(duration)) } else { clock(position) }];
        match self {
            Resume::Episode { show, .. } | Resume::Recording { show: Some(show), .. } => parts.push(show.clone()),
            Resume::Recording { show: None, .. } => {}
        }
        parts.join(" · ")
    }

    fn resume(&self) {
        match self {
            Resume::Recording { id, .. } => store().resume(id),
            Resume::Episode { episode, show, .. } => play_episode((**episode).clone(), show.clone()),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
struct Fresh {
    episode: Episode,
    show: String,
    feed_url: String,
    artwork: String,
}

fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_millis() as i64)
}

fn resumable() -> Vec<Resume> {
    let store = store();
    let jobs = store.jobs();
    let mut items: Vec<Resume> = store
        .played()
        .into_iter()
        .filter(|(id, ..)| store.shelved(Shelf::Continue, id))
        .filter_map(|(id, at, position)| {
            let job = jobs.iter().find(|job| job.id == id && job.has_transcript())?;
            let (glyph, artwork) = job_glyph(job);
            Some(Resume::Recording {
                title: job.title(),
                glyph,
                artwork,
                show: podcasts::show_of(job),
                duration: job.duration_ms(),
                id,
                position,
                at,
            })
        })
        .collect();
    let feeds = store.podcast.feeds();
    items.extend(
        store
            .podcast
            .listening()
            .into_iter()
            .filter(|entry| entry.is_continuable() && store.shelved(Shelf::Continue, &entry.episode_id))
            .filter_map(|entry| {
                let (feed, episode) = feeds.iter().find_map(|feed| {
                    feed.episodes.iter().find(|e| e.id == entry.episode_id).map(|episode| (feed, episode))
                })?;
                Some(Resume::Episode {
                    artwork: episode.artwork_url.clone().or_else(|| feed.artwork_url.clone()).unwrap_or_default(),
                    episode: Box::new(episode.clone()),
                    show: feed.title.clone(),
                    position: entry.position_ms,
                    duration: entry.duration_ms.max(episode.duration_ms.unwrap_or(0)),
                    at: entry.updated_at.unwrap_or_default(),
                })
            }),
    );
    items.sort_by(|a, b| b.at().cmp(a.at()));
    items.truncate(CONTINUED);
    items
}

fn fresh_episodes() -> Vec<Fresh> {
    let store = store();
    let followed: Vec<String> = store.podcast.followed().into_iter().map(|f| f.feed_url).collect();
    let heard: Vec<String> = store.podcast.listening().into_iter().map(|entry| entry.episode_id).collect();
    let kept: Vec<String> =
        store.jobs().iter().filter_map(|job| job.podcast_provenance.as_ref().map(|p| p.episode_id.clone())).collect();
    let since = iso_from_millis(now_ms() - NEW_FOR_DAYS * 24 * 60 * 60 * 1000).unwrap_or_default();
    let mut fresh: Vec<Fresh> = store
        .podcast
        .feeds()
        .into_iter()
        .filter(|feed| followed.contains(&feed.feed_url))
        .flat_map(|feed| {
            let artwork = feed.artwork_url.clone().unwrap_or_default();
            feed.episodes
                .into_iter()
                .filter(|e| e.published_at.as_deref().is_some_and(|at| at >= since.as_str()))
                .filter(|e| !heard.contains(&e.id) && !kept.contains(&e.id))
                .map(|episode| Fresh {
                    artwork: episode.artwork_url.clone().unwrap_or_else(|| artwork.clone()),
                    show: feed.title.clone(),
                    feed_url: feed.feed_url.clone(),
                    episode,
                })
                .collect::<Vec<_>>()
        })
        .collect();
    fresh.sort_by(|a, b| b.episode.published_at.cmp(&a.episode.published_at));
    fresh.truncate(NEW_EPISODES);
    fresh
}

fn refresh_followed() {
    let store = store();
    let stale = iso_from_millis(now_ms() - FEED_STALE_MS).unwrap_or_default();
    for followed in store.podcast.followed() {
        let fetched = store.podcast.feed(&followed.feed_url).and_then(|feed| feed.fetched_at);
        if fetched.is_some_and(|at| at >= stale) {
            continue;
        }
        spawn(podcasts::refresh(followed.feed_url));
    }
}

fn play_episode(episode: Episode, show: String) {
    let store = store();
    let player = store.podcast;
    if player.is_current(&episode.id) {
        player.set_paused(false);
        return;
    }
    let local = podcasts::job_of(&episode.id)
        .and_then(|id| store.job_now(&id))
        .filter(|job| std::path::Path::new(&job.source_path).exists());
    let source = local.map_or_else(|| episode.enclosure_url.clone(), |job| file_url(&job.source_path));
    player.play(episode, show.into(), source);
}

fn open_show(feed_url: &str) {
    let store = store();
    store.go(Place::Podcasts);
    store.podcast.open_show.set(Some(feed_url.to_owned()));
}

pub(crate) fn home() -> impl IntoElement {
    let store = store();
    let query = signal(String::new());
    refresh_followed();
    let continued = computed(resumable);
    let recent = computed(move || {
        let mut jobs: Vec<Rc<Job>> =
            store.jobs().into_iter().filter(|job| store.shelved(Shelf::Recent, &job.id)).collect();
        jobs.sort_by(|a, b| b.created_at.cmp(&a.created_at));
        jobs.truncate(RECENT);
        jobs
    });
    let processing = computed(move || store.jobs().into_iter().filter(|job| job.is_busy()).collect::<Vec<_>>());
    let waiting = computed(move || store.jobs().iter().filter(|job| job.status.is_transcribable()).count());
    let fresh = computed(fresh_episodes);
    let found = computed(move || {
        let needle = query.with(|q| q.trim().to_lowercase());
        if needle.is_empty() {
            return Vec::new();
        }
        store
            .jobs()
            .into_iter()
            .filter(|job| {
                job.title().to_lowercase().contains(&needle) || job.file_name().to_lowercase().contains(&needle)
            })
            .collect::<Vec<Rc<Job>>>()
    });
    let open = store.home_search();
    effect(move || {
        if !open.get() {
            query.set(String::new());
        }
    });
    on_key("mod+f", move |_| open.set(true));
    let searching = move || query.with(|q| !q.trim().is_empty());
    let bare = move || {
        store.jobs().is_empty() && store.podcast.followed().is_empty() && continued.with(|items| items.is_empty())
    };
    view()
        .flex_1()
        .child(when(
            || !system_header(),
            move || {
                top_bar().child(view().flex_1()).child(
                    view()
                        .flex_row()
                        .items_center()
                        .gap_1()
                        .window_drag(false)
                        .child(ui::icon_button(Icon::Search, tr("Search"), Size::Sm, move || open.set(true)))
                        .child(super::capture::add_button()),
                )
            },
        ))
        .child(when(
            move || open.get(),
            move || {
                // Escape is a key text inputs keep, so the default binding would not reach
                // past the focused search field; bind it only while the bar is open.
                on_key_with(
                    "escape",
                    KeyOptions { when: nsh_core::keymap::When::Always, ..KeyOptions::default() },
                    move |_| open.set(false),
                );
                view()
                    .flex_row()
                    .items_center()
                    .gap_2()
                    .w_full()
                    .max_w(px(960.0))
                    .self_center()
                    .px(px(ui::PAGE_INSET))
                    .pt_3()
                    .child(focused_search_field(query, l("Search your library")).flex_1())
                    .child(ui::button(Variant::Ghost, Size::Md, l("Cancel")).on_press(move || open.set(false)))
            },
        ))
        .child(
            when(bare, || {
                empty_state(
                    Icon::Wave,
                    l("Start your library"),
                    move || {
                        tr(if platform::is_phone() {
                            "Add audio or video, or follow a podcast. What you play shows up here."
                        } else {
                            "Drop audio or video here, or follow a podcast. What you play shows up here."
                        })
                    },
                    view()
                        .flex_row()
                        .flex_wrap()
                        .justify_center()
                        .gap_2()
                        .child(
                            icon_text_button(Variant::Primary, Size::Md, Icon::Plus, l("Add media…"))
                                .on_press(util::pick_media),
                        )
                        .child(when(super::capture::offered, || {
                            icon_text_button(Variant::Outline, Size::Md, Icon::Record, l("Record what’s playing"))
                                .on_press(|| crate::state::store().capture.record())
                        })),
                )
            })
            .otherwise(move || {
                scroll().flex_1().child(
                    view()
                        .w_full()
                        .max_w(px(960.0))
                        .self_center()
                        .px(px(ui::PAGE_INSET))
                        .pt(px(ui::PAGE_INSET))
                        .pb(px(ui::PAGE_INSET))
                        .gap_6()
                        .child(when(searching, move || results(found)).otherwise(move || {
                            let has_continue = move || continued.with(|items| !items.is_empty());
                            let beside = move || home_stats::beside();
                            view()
                                .gap_6()
                                .child(
                                    view()
                                        .style_with(move |s| if beside() { s.flex_row().gap_4() } else { s.gap_6() })
                                        .child(
                                            view()
                                                .style_with(move |s| {
                                                    if beside() && has_continue() {
                                                        s.w(px(300.0)).flex_shrink_0()
                                                    } else {
                                                        s.w_full()
                                                    }
                                                })
                                                .child(home_stats::today_card(move || beside() && has_continue())),
                                        )
                                        .child(when(has_continue, move || {
                                            view()
                                                .flex_1()
                                                .min_w(px(0.0))
                                                .child(section("Continue", None, continue_section(continued)).flex_1())
                                        })),
                                )
                                .child(when(home_stats::has_history, home_stats::activity_card))
                                .child(when(
                                    move || processing.with(|jobs| !jobs.is_empty()) || waiting.get() > 0,
                                    move || section("Processing", None, processing_section(processing, waiting)),
                                ))
                                .child(when(
                                    move || recent.with(|jobs| !jobs.is_empty()),
                                    move || {
                                        section(
                                            "Recently added",
                                            Some(("See all", Rc::new(move || store.show(Filter::All)))),
                                            recent_grid(recent),
                                        )
                                    },
                                ))
                                .child(when(
                                    move || fresh.with(|episodes| !episodes.is_empty()),
                                    move || {
                                        section(
                                            "New episodes",
                                            Some(("Podcasts", Rc::new(move || store.go(Place::Podcasts)))),
                                            fresh_list(fresh),
                                        )
                                    },
                                ))
                        })),
                )
            }),
        )
}

type Link = (&'static str, Rc<dyn Fn()>);

fn section(title: &'static str, link: Option<Link>, content: impl IntoElement) -> View {
    let header = view().flex_row().items_center().justify_between().min_h(px(Size::Sm.height())).child(
        text(l(title))
            .text_base()
            .font_weight(FontWeight::SEMIBOLD)
            .text_color(|| theme().foreground)
            .role(AccessibilityRole::Header),
    );
    let header = match link {
        Some((label, go)) => header.child(ui::button(Variant::Ghost, Size::Sm, l(label)).on_press(move || go())),
        None => header,
    };
    view().gap_3().child(header).child(content)
}

fn take_off(shelf: Shelf, id: String) {
    let store = store();
    store.shelve(shelf, &id, false);
    let done = match shelf {
        Shelf::Continue => "Removed from Continue",
        Shelf::Recent => "Removed from Recently added",
    };
    toast_with_action(Tone::Info, tr(done), tr("Undo"), move || store.shelve(shelf, &id, true));
}

fn removable(shelf: Shelf, id: String, target: impl IntoElement) -> impl IntoElement {
    let label = match shelf {
        Shelf::Continue => "Remove from Continue",
        Shelf::Recent => "Remove from Recently added",
    };
    ui::context_menu(target).child(ui::menu_action(Icon::Close, l(label), move || take_off(shelf, id.clone())))
}

fn tile_icon(glyph: Icon, artwork: Art, size: f32) -> View {
    let tile = view()
        .size(px(size))
        .flex_shrink_0()
        .rounded(tokens::radius)
        .overflow_hidden()
        .items_center()
        .justify_center()
        .bg(|| theme().muted)
        .text_color(|| theme().muted_foreground)
        .child(icon(glyph, size * 0.42).absolute());
    let shown = artwork.clone();
    tile.child(when(
        move || !shown.get().is_empty(),
        move || {
            let artwork = artwork.clone();
            image(move || artwork.get()).size(px(size)).object_fit(ResizeMode::Cover)
        },
    ))
}

fn job_tile(job: &Job) -> View {
    let (glyph, artwork) = job_glyph(job);
    tile_icon(glyph, artwork, 36.0)
}

fn job_glyph(job: &Job) -> (Icon, Art) {
    let glyph = kind_icon(job);
    let artwork = match glyph {
        Icon::Podcast => Art::Url(podcasts::artwork_of(job)),
        Icon::Film | Icon::Headphones => Art::File(artwork::File::of(job)),
        _ => Art::Url(String::new()),
    };
    (glyph, artwork)
}

fn resume_glyph(item: &Resume) -> (Icon, Art) {
    match item {
        Resume::Recording { glyph, artwork, .. } => (*glyph, artwork.clone()),
        Resume::Episode { artwork, .. } => (Icon::Podcast, Art::Url(artwork.clone())),
    }
}

fn continue_section(continued: Memo<Vec<Resume>>) -> impl IntoElement {
    dynamic(move || {
        let items = continued.get();
        let mut items = items.into_iter();
        let Some(first) = items.next() else {
            return view().into_element();
        };
        let rest: Vec<Resume> = items.collect();
        // Beside Today the lead card takes the height Today leaves over.
        view()
            .flex_1()
            .gap_3()
            .child(view().flex_1().child(lead_card(first)))
            .child(when(
                {
                    let empty = rest.is_empty();
                    move || !empty
                },
                move || {
                    view()
                        .style_with(|s| if page_narrow() { s.gap_2() } else { s.flex_row().gap_3() })
                        .children(rest.clone().into_iter().map(small_card))
                },
            ))
            .into_element()
    })
}

fn lead_card(item: Resume) -> impl IntoElement {
    let (glyph, artwork) = resume_glyph(&item);
    let (title, meta, fraction) = (item.title(), item.meta(), item.fraction());
    let label = format!("{} {}", tr("Resume"), title);
    let id = item.id().to_owned();
    let pressed = item.clone();
    let lead = card().flex_1().child(
        ui::pressable_card()
            .on_press(move || pressed.resume())
            .accessibility_label(label)
            .flex_1()
            .flex_row()
            .items_center()
            .gap_4()
            .p_4()
            .child(tile_icon(glyph, artwork, 64.0))
            .child(
                view()
                    .flex_1()
                    .min_w(px(0.0))
                    .gap_1()
                    .child(
                        text(SharedString::from(title))
                            .text_base()
                            .font_weight(FontWeight::SEMIBOLD)
                            .number_of_lines(2)
                            .text_color(|| theme().foreground),
                    )
                    .child(
                        text(SharedString::from(meta))
                            .text_sm()
                            .tabular_nums()
                            .number_of_lines(1)
                            .text_color(|| theme().muted_foreground),
                    )
                    .child(progress_bar(move || fraction).mt_2().max_w(px(360.0))),
            )
            .child(
                view()
                    .size(px(44.0))
                    .flex_shrink_0()
                    .rounded_full()
                    .items_center()
                    .justify_center()
                    .bg(|| theme().primary)
                    .text_color(|| theme().primary_foreground)
                    .child(icon(Icon::Play, 20.0)),
            ),
    );
    removable(Shelf::Continue, id, lead)
}

fn small_card(item: Resume) -> impl IntoElement {
    let (glyph, artwork) = resume_glyph(&item);
    let (title, meta, fraction) = (item.title(), item.meta(), item.fraction());
    let label = format!("{} {}", tr("Resume"), title);
    let id = item.id().to_owned();
    let small = card().child(
        ui::pressable_card()
            .on_press(move || item.resume())
            .accessibility_label(label)
            .flex_row()
            .items_center()
            .gap_3()
            .p_3()
            .child(tile_icon(glyph, artwork, 40.0))
            .child(
                view()
                    .flex_1()
                    .min_w(px(0.0))
                    .gap_0p5()
                    .child(
                        text(SharedString::from(title))
                            .text_sm()
                            .font_weight(FontWeight::MEDIUM)
                            .number_of_lines(1)
                            .text_color(|| theme().foreground),
                    )
                    .child(
                        text(SharedString::from(meta))
                            .text_xs()
                            .tabular_nums()
                            .number_of_lines(1)
                            .text_color(|| theme().muted_foreground),
                    )
                    .child(progress_bar(move || fraction).mt_1()),
            )
            .child(view().text_color(|| theme().muted_foreground).child(icon(Icon::Play, 16.0))),
    );
    view().flex_1().min_w(px(0.0)).child(removable(Shelf::Continue, id, small))
}

fn processing_section(processing: Memo<Vec<Rc<Job>>>, waiting: Memo<usize>) -> impl IntoElement {
    let store = store();
    view()
        .child(each(
            move || processing.get(),
            |job| job.id.clone(),
            move |job, _| {
                let id = job.with_untracked(|job| job.id.clone());
                let fraction = computed(move || store.job(&id).and_then(|job| job.progress.fraction.map(|f| f as f32)));
                list_row(|| false)
                    .on_press(move || store.show(Filter::InProgress))
                    .child(job.with_untracked(|job| job_tile(job)))
                    .child(
                        view()
                            .flex_1()
                            .min_w(px(0.0))
                            .gap_0p5()
                            .child(
                                text(move || job.with(|job| SharedString::from(job.title())))
                                    .text_sm()
                                    .font_weight(FontWeight::MEDIUM)
                                    .number_of_lines(1)
                                    .text_color(|| theme().foreground),
                            )
                            .child(
                                text(move || job.with(|job| detail(job)))
                                    .text_xs()
                                    .number_of_lines(1)
                                    .text_color(|| theme().muted_foreground),
                            )
                            .child(progress_bar(move || fraction.get()).mt_1()),
                    )
            },
        ))
        .child(when(
            move || waiting.get() > 0,
            move || {
                view()
                    .flex_row()
                    .items_center()
                    .gap_3()
                    .px_3()
                    .py_2()
                    .child(
                        text(move || {
                            SharedString::from(format!("{} {}", waiting.get(), tr("waiting to be transcribed")))
                        })
                        .flex_1()
                        .text_sm()
                        .text_color(|| theme().muted_foreground),
                    )
                    .child(
                        icon_text_button(Variant::Outline, Size::Sm, Icon::Transcribe, l("Transcribe all"))
                            .on_press(transcribe::start_ready),
                    )
            },
        ))
}

fn recent_grid(recent: Memo<Vec<Rc<Job>>>) -> impl IntoElement {
    let store = store();
    // Tiles across on a wide page; on a phone a card spans the page, so
    // one a row with the words beside the icon.
    let columns = || -> SharedString {
        if page_narrow() { "1fr".into() } else { "repeat(auto-fill, minmax(176px, 1fr))".into() }
    };
    view().grid().grid_template_columns(columns).gap_3().child(each(
        move || recent.get(),
        |job| job.id.clone(),
        move |job, _| {
            let id = job.with_untracked(|job| job.id.clone());
            let readable = job.with_untracked(|job| job.has_transcript());
            let opened = id.clone();
            let tile = card().flex_1().child(
                ui::pressable_card()
                    .on_press(move || if readable { store.open_transcript(&opened) } else { store.show(Filter::All) })
                    .gap_3()
                    .p_3()
                    .style_with(|s| if page_narrow() { s.flex_row().items_center() } else { s })
                    .child(job.with_untracked(|job| job_tile(job)))
                    .child(
                        view()
                            .flex_1()
                            .min_w(px(0.0))
                            .gap_0p5()
                            .child(
                                text(move || job.with(|job| SharedString::from(job.title())))
                                    .text_sm()
                                    .font_weight(FontWeight::MEDIUM)
                                    .number_of_lines(2)
                                    .text_color(|| theme().foreground),
                            )
                            .child(
                                text(move || {
                                    job.with(|job| {
                                        let mut parts = Vec::new();
                                        if job.duration_ms() > 0 {
                                            parts.push(clock(job.duration_ms()));
                                        }
                                        parts.push(date(&job.created_at));
                                        parts.extend(podcasts::show_of(job));
                                        SharedString::from(parts.join(" · "))
                                    })
                                })
                                .text_xs()
                                .tabular_nums()
                                .number_of_lines(1)
                                .text_color(|| theme().muted_foreground),
                            ),
                    ),
            );
            removable(Shelf::Recent, id, tile)
        },
    ))
}

fn fresh_list(fresh: Memo<Vec<Fresh>>) -> impl IntoElement {
    let player = store().podcast;
    view().child(each(
        move || fresh.get(),
        |fresh| fresh.episode.id.clone(),
        move |item, _| {
            let Fresh { episode, show, feed_url, artwork } = item.get_untracked();
            let id = episode.id.clone();
            let playing = computed(move || player.is_current(&id) && !player.paused());
            let playing = move || playing.get();
            let mut parts = Vec::new();
            parts.push(show.clone());
            if let Some(published) = &episode.published_at {
                parts.push(date(published));
            }
            if let Some(duration) = episode.duration_ms {
                parts.push(duration_words(duration));
            }
            let title = episode.title.clone();
            view()
                .flex_row()
                .items_center()
                .gap_1()
                .child(
                    list_row(|| false)
                        .on_press(move || open_show(&feed_url))
                        .flex_1()
                        .min_w(px(0.0))
                        .child(tile_icon(Icon::Podcast, Art::Url(artwork), 40.0))
                        .child(
                            view()
                                .flex_1()
                                .min_w(px(0.0))
                                .gap_0p5()
                                .child(
                                    text(SharedString::from(title))
                                        .text_sm()
                                        .font_weight(FontWeight::MEDIUM)
                                        .number_of_lines(1)
                                        .text_color(|| theme().foreground),
                                )
                                .child(
                                    text(SharedString::from(parts.join(" · ")))
                                        .text_xs()
                                        .number_of_lines(1)
                                        .text_color(|| theme().muted_foreground),
                                ),
                        ),
                )
                .child(
                    toggle_icon_button(
                        move || if playing() { Icon::Pause } else { Icon::Play },
                        move || if playing() { tr("Pause playback") } else { tr("Play") },
                        Variant::Ghost,
                        Size::Md,
                    )
                    .on_press(move || {
                        if playing() {
                            player.set_paused(true);
                        } else {
                            play_episode(episode.clone(), show.clone());
                        }
                    }),
                )
        },
    ))
}

fn results(found: Memo<Vec<Rc<Job>>>) -> impl IntoElement {
    let store = store();
    view()
        .child(each(
            move || found.get(),
            |job| job.id.clone(),
            move |job, _| {
                let id = job.with_untracked(|job| job.id.clone());
                let readable = job.with_untracked(|job| job.has_transcript());
                list_row(|| false)
                    .on_press(move || if readable { store.open_transcript(&id) } else { store.show(Filter::All) })
                    .child(job.with_untracked(|job| job_tile(job)))
                    .child(
                        view()
                            .flex_1()
                            .min_w(px(0.0))
                            .gap_0p5()
                            .child(
                                text(move || job.with(|job| SharedString::from(job.title())))
                                    .text_sm()
                                    .font_weight(FontWeight::MEDIUM)
                                    .number_of_lines(1)
                                    .text_color(|| theme().foreground),
                            )
                            .child(
                                text(move || job.with(|job| detail(job)))
                                    .text_xs()
                                    .number_of_lines(1)
                                    .text_color(|| theme().muted_foreground),
                            ),
                    )
            },
        ))
        .child(when(
            move || found.with(Vec::is_empty),
            || text(l("No recordings match your search.")).text_sm().py_2().text_color(|| theme().muted_foreground),
        ))
}
