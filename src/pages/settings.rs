use listenook_core::{LlmProvider, LocaleMode, ThemeMode, transcript::local::Model};

use nsh_base::theme;
use nsh_core::prelude::*;

use crate::services::{
    chatgpt::{self, Account},
    secrets::{self, Secret},
};
use crate::state::monitor::MonitorState;
use crate::ui::{error_text, l, tr};
use crate::work::{ai, updater};
use crate::{
    services::{
        local::{self, ModelState},
        remote::Provider,
    },
    state::{SettingsTab as Tab, store},
    ui::{
        Badge, BoundFieldWith, KeyCap, ModalSized, Segmented, Separator, Size, Status, Tone, Variant, button, card,
        confirm_destructive, field, hint, progress_bar, section, select, switch, text_field_with, toast,
    },
};

const TABS: [Tab; 5] = [Tab::General, Tab::Transcription, Tab::Ai, Tab::Shortcuts, Tab::About];

fn tab_key(tab: Tab) -> &'static str {
    match tab {
        Tab::General => "General",
        Tab::Transcription => "Transcription",
        Tab::Ai => "AI",
        Tab::Shortcuts => "Shortcuts",
        Tab::About => "About",
    }
}

pub(crate) const VERSION: &str = match option_env!("LISTENOOK_VERSION") {
    Some(version) => version,
    None => env!("CARGO_PKG_VERSION"),
};

/// The version About shows: the installed app's, with its build number, as its package says;
/// the one it was compiled as in a development run.
fn shown_version() -> String {
    match app_info() {
        Some(info) if !info.development => match (info.version, info.build) {
            (Some(version), Some(build)) => format!("{version} ({build})"),
            (Some(version), None) => version,
            _ => VERSION.to_owned(),
        },
        _ => VERSION.to_owned(),
    }
}

pub(crate) fn settings_dialog() -> impl IntoElement {
    let open = store().settings_open();
    let tab = store().settings_tab();
    ModalSized {
        open,
        title: l("Settings"),
        width: 720.0,
        height: Some(620.0),
        content: move || {
            view()
                .gap_5()
                .child(
                    when(crate::platform::compact, move || {
                        scroll().horizontal().scrollbar(false).child(Segmented {
                            options: TABS.iter().map(|tab| (*tab, tab_key(*tab))).collect(),
                            value: move || tab.get(),
                            on_change: move |next| tab.set(next),
                        })
                    })
                    .otherwise(move || Segmented {
                        options: TABS.iter().map(|tab| (*tab, tab_key(*tab))).collect(),
                        value: move || tab.get(),
                        on_change: move |next| tab.set(next),
                    }),
                )
                .child(dynamic(move || {
                    let tab = tab.get();
                    untracked(|| match tab {
                        Tab::General => general().into_element(),
                        Tab::Transcription => transcription().into_element(),
                        Tab::Ai => ai().into_element(),
                        Tab::Shortcuts => shortcuts().into_element(),
                        Tab::About => about().into_element(),
                    })
                }))
                .into_element()
        },
        actions: move || button(Variant::Default, Size::Md, l("Done")).on_press(move || open.set(false)).into_element(),
    }
}

fn panel() -> View {
    card().p_4().gap_4()
}

fn general() -> impl IntoElement {
    let store = store();
    view().gap_6().child(section(
        l("Appearance"),
        panel()
            .child(field(
                l("Theme"),
                Segmented { options: vec![
                        (ThemeMode::System, "System"),
                        (ThemeMode::Light, "Light"),
                        (ThemeMode::Dark, "Dark"),
                    ], value: move || store.setting(|s| s.theme_mode), on_change: move |mode| store.update_settings(|s| s.theme_mode = mode) },
            ))
            .child(field(
                l("Language"),
                Segmented { options: vec![
                        (LocaleMode::System, "System"),
                        (LocaleMode::English, "English"),
                        (LocaleMode::SimplifiedChinese, "简体中文"),
                    ], value: move || store.setting(|s| s.locale_mode), on_change: move |mode| store.update_settings(|s| s.locale_mode = mode) },
            ))
    ))
    .child(section(
        l("Learning"),
        panel().child(
            field(
                l("Daily goal"),
                dynamic(move || {
                    store.lang();
                    untracked(move || {
                        select(
                            "Daily goal",
                            super::home_stats::GOALS
                                .iter()
                                .map(|minutes| {
                                    (minutes.to_string().into(), super::home_stats::goal_choice(*minutes).into())
                                })
                                .collect(),
                            move || SharedString::from(store.daily_goal_minutes().to_string()),
                            move |value| {
                                if let Ok(minutes) = value.parse() {
                                    store.act(crate::state::Action::SetDailyGoalMinutes(minutes));
                                }
                            },
                        )
                        .w(px(240.0))
                        .into_element()
                    })
                }),
            )
            .child(hint(l("Time spent playing and practicing counts toward it. Home shows how today is going."))),
        ),
    ))
    .child(section(
        l("Background"),
        panel()
            .child(switch(l("Notify me when transcriptions and downloads finish"), move || store.setting(|s| s.extra.get("notify_when_done").and_then(|v| v.as_bool()).unwrap_or(true)), move |on| store.update_settings(|s| drop(s.extra.insert("notify_when_done".into(), on.into())))))
            .child(notifications_turned_off())
            .child(when(crate::platform::has_tray, move || {
                view()
                    .gap_1()
                    .child(switch(l(if cfg!(target_os = "macos") {
                            "Keep Listenook in the menu bar"
                        } else {
                            "Keep Listenook in the tray"
                        }), move || MonitorState::get().tray_enabled(), move |on| MonitorState::get().act(crate::state::monitor::MonitorAction::SetTrayEnabled(on)))
                    .disabled(move || !MonitorState::get().dock_visible()))
                    .child(hint(move || {
                        tr(if MonitorState::get().dock_visible() {
                            "Closing the window then hides it; Listenook keeps running."
                        } else {
                            "Show the Dock icon first, so Listenook stays reachable."
                        })
                    }))
            }))
            .child(when(|| cfg!(target_os = "macos"), move || {
                view()
                    .gap_1()
                    .child(
                        switch(l("Show Dock icon"), move || MonitorState::get().dock_visible(), move |on| MonitorState::get().act(crate::state::monitor::MonitorAction::SetDockVisible(on)))
                            .disabled(move || !MonitorState::get().tray_enabled()),
                    )
                    .child(hint(move || {
                        tr(if MonitorState::get().tray_enabled() {
                            "When hidden, the menu bar icon opens Listenook and its settings."
                        } else {
                            "Show the menu bar icon first, so Listenook stays reachable."
                        })
                    }))
            }))
            .child(when(crate::services::login::supported, move || {
                view()
                    .gap_1()
                    .child(switch(l("Open Listenook at login"), move || MonitorState::get().opens_at_login(), move |on| MonitorState::get().act(crate::state::monitor::MonitorAction::SetOpensAtLogin(on))))
                    .child(when(move || MonitorState::get().tray_enabled(), || {
                        hint(l(if cfg!(target_os = "macos") {
                            "Starts hidden in the menu bar."
                        } else {
                            "Starts hidden in the system tray."
                        }))
                    }))
            })),
    ))
    .child(when(|| !crate::platform::is_phone(), move || section(
        l("Watched folder"),
        panel()
            .child(hint(l("Audio and video that appear in this folder, and its subfolders, are added to the Library. Nothing is transcribed until you ask.")))
            .child(
                when(move || MonitorState::get().config().folder_path.is_empty(), move || {
                    button(Variant::Default, Size::Md, l("Choose folder")).self_start().on_press(choose_watched_folder)
                })
                .otherwise(move || {
                    view()
                        .gap_3()
                        .child(
                            text(move || SharedString::from(MonitorState::get().config().folder_path))
                                .text_sm()
                                .number_of_lines(2)
                                .text_color(|| theme().foreground),
                        )
                        .child(switch(l("Watching"), move || !MonitorState::get().config().paused, move |on| MonitorState::get().act(crate::state::monitor::MonitorAction::SetPaused(!on))))
                        .child(
                            view()
                                .flex_row()
                                .gap_2()
                                .child(button(Variant::Outline, Size::Md, l("Change folder")).on_press(choose_watched_folder))
                                .child(button(Variant::Ghost, Size::Md, l("Stop watching")).on_press(move || MonitorState::get().act(crate::state::monitor::MonitorAction::WatchFolder("")))),
                        )
                }),
            ),
    )))
    .child(paired_devices())
}

fn paired_devices() -> impl IntoElement {
    let store = store();
    let sync = crate::work::sync::SyncState::get();
    let paired = move || !sync.mates().is_empty();
    let leave = move || {
        confirm_destructive(
            tr("Unpair this device?"),
            tr("It stops syncing with all your devices, and they forget it. What is already here stays."),
            tr("Cancel"),
            tr("Unpair"),
            move || sync.act(crate::work::sync::SyncAction::Leave),
        );
    };
    section(
        l("Paired devices"),
        panel()
            .child(hint(move || {
                if paired() {
                    tr("This device syncs on its own with these devices whenever both are open on the same network or on Tailscale. Recordings over 500 MB are copied only when you sync yourself, and over Tailscale only when you ask for them.")
                } else {
                    tr("This device is not paired with any other. Open Sync to pair one with a code.")
                }
            }))
            .child(view().gap_1().child(each(move || sync.mates(), |mate| mate.id.clone(), move |mate, _| crate::pages::mate_row(mate))))
            .child(
                when(paired, move || {
                    button(Variant::Outline, Size::Md, l("Unpair this device")).self_start().on_press(leave)
                })
                .otherwise(move || {
                    button(Variant::Default, Size::Md, l("Open Sync")).self_start().on_press(move || {
                        store.settings_open().set(false);
                        sync.act(crate::work::sync::SyncAction::Show);
                    })
                }),
            ),
    )
}

fn key_field(
    secret: Secret,
    keyless: impl Fn() -> bool + Copy + 'static,
    test: impl Fn(String, Signal<SharedString>, Signal<Option<String>>) + Copy + 'static,
) -> impl IntoElement {
    let draft = signal(String::new());
    let saved = signal(secrets::read(secret).is_some());
    let status = signal(SharedString::default());
    // The last key that passed Test. Save stays off until the key being typed is that one.
    let verified = signal(None::<String>);
    let save = move || {
        let value = draft.get_untracked();
        match store().write_key(secret, &value) {
            Ok(()) => {
                batch(|| {
                    saved.set(!value.trim().is_empty());
                    draft.set(String::new());
                    verified.set(None);
                    status.set(SharedString::default());
                });
                toast(
                    Tone::Success,
                    tr(if secrets::uses_system_store() { "Key saved in the system keychain." } else { "Key saved." }),
                );
            }
            Err(error) => {
                log::error!("saving a key: {error}");
                toast(Tone::Error, tr("Couldn’t save the key. Unlock your keychain and try again."));
            }
        }
    };
    let remove = move || {
        confirm_destructive(
            tr("Remove this API key?"),
            tr("What uses it stops working until you paste a key again."),
            tr("Cancel"),
            tr("Remove"),
            move || {
                if store().write_key(secret, "").is_ok() {
                    saved.set(false);
                    status.set(SharedString::default());
                }
            },
        );
    };
    view()
        .gap_2()
        .child(
            // The buttons go under the key when there is no room for both.
            view()
                .flex_row()
                .flex_wrap()
                .items_center()
                .gap_2()
                .child(
                    text_field_with(
                        draft,
                        move || {
                            if saved.get() {
                                "••••••••••••••••".into()
                            } else {
                                tr("Paste your API key")
                            }
                        },
                        |input| input.masked(true),
                    )
                    .flex_1()
                    .min_w(px(220.0)),
                )
                .child(
                    view()
                        .flex_row()
                        .gap_2()
                        .child(
                            button(Variant::Default, Size::Md, l("Save"))
                                .disabled(move || {
                                    draft.with(|d| {
                                        let typed = d.trim();
                                        typed.is_empty() || verified.with(|v| v.as_deref() != Some(typed))
                                    })
                                })
                                .on_press(save),
                        )
                        .child(
                            button(Variant::Outline, Size::Md, l("Test"))
                                .disabled(move || !keyless() && !saved.get() && draft.with(|d| d.trim().is_empty()))
                                .on_press(move || {
                                    let typed = draft.get_untracked().trim().to_owned();
                                    let key = if typed.is_empty() {
                                        secrets::read(secret).unwrap_or_default()
                                    } else {
                                        typed
                                    };
                                    status.set(tr("Testing…"));
                                    verified.set(None);
                                    test(key, status, verified);
                                }),
                        )
                        .child(
                            button(Variant::Danger, Size::Md, l("Remove"))
                                .disabled(move || !saved.get())
                                .on_press(remove),
                        ),
                ),
        )
        .child(
            view()
                .flex_row()
                .items_center()
                .gap_2()
                .child(
                    when(saved, || Badge { label: l("Saved"), status: || Status::Success })
                        .otherwise(|| Badge { label: l("Setup required"), status: || Status::Warning }),
                )
                .child(hint(status)),
        )
}

fn test_provider(provider: Provider) -> impl Fn(String, Signal<SharedString>, Signal<Option<String>>) + Copy + 'static {
    move |key, status, verified| {
        store().run(async move {
            let result = provider.validate_key(&key).await;
            status.try_set(match result {
                Ok(()) => {
                    verified.try_set(Some(key));
                    format!("{} {}", provider.name(), tr("key is valid.")).into()
                }
                Err(failure) => error_text(&failure.code),
            });
        });
    }
}

fn transcription() -> impl IntoElement {
    let store = store();
    let soniox_languages: Vec<(SharedString, SharedString)> = listenook_core::TRANSLATION_LANGUAGES
        .iter()
        .filter(|(code, _)| !code.contains('-') && *code != "yue")
        .map(|(code, name)| ((*code).into(), (*name).into()))
        .chain([("zh".into(), "Chinese".into())])
        .collect();
    view()
        .gap_6()
        .child(section(
            "Soniox",
            panel()
                .child(hint(l(
                    "Speaker labels, word timing, language detection and optional translation during transcription.",
                )))
                .child(field(l("API key"), key_field(Secret::Soniox, || false, test_provider(Provider::Soniox))))
                .child(Separator)
                .child(switch(
                    l("Translate during transcription"),
                    move || store.setting(|s| s.soniox_translation.enabled),
                    move |on| {
                        store.update_settings(|s| {
                            s.soniox_translation.enabled = on;
                            if s.soniox_translation.target_language.is_empty() {
                                s.soniox_translation.target_language = "en".into();
                            }
                        })
                    },
                ))
                .child(when(
                    move || store.setting(|s| s.soniox_translation.enabled),
                    move || {
                        field(
                            l("Target language"),
                            select(
                                "Soniox target language",
                                soniox_languages.clone(),
                                move || {
                                    SharedString::from(store.setting(|s| s.soniox_translation.target_language.clone()))
                                },
                                move |value| {
                                    store.update_settings(|s| s.soniox_translation.target_language = value.to_string())
                                },
                            )
                            .w(px(240.0)),
                        )
                    },
                )),
        ))
        .child(section(
            "MOSS Pro",
            panel()
                .child(hint(l(
                    "Multilingual transcription with speaker labels through MOSI. Language and context are automatic.",
                )))
                .child(field(l("API key"), key_field(Secret::Moss, || false, test_provider(Provider::Moss)))),
        ))
        .child(when(local::supported, on_this_mac))
}

fn state_of(models: &'static [Model]) -> ModelState {
    let states: Vec<ModelState> = models.iter().map(local::model_state).collect();
    let size = |model: &Model| model.size() as f64;
    if states.iter().any(|state| matches!(state, ModelState::Downloading(_))) {
        let done: f64 = models
            .iter()
            .zip(&states)
            .map(|(model, state)| match state {
                ModelState::Downloading(fraction) => fraction * size(model),
                ModelState::Ready => size(model),
                _ => 0.0,
            })
            .sum();
        ModelState::Downloading(done / models.iter().map(size).sum::<f64>().max(1.0))
    } else if states.iter().all(|state| *state == ModelState::Ready) {
        ModelState::Ready
    } else if states.iter().any(|state| *state != ModelState::Missing) {
        ModelState::Partial
    } else {
        ModelState::Missing
    }
}

fn model_row(title: &'static str, about: &'static str, models: &'static [Model]) -> impl IntoElement {
    let store = store();
    let state = move || state_of(models);
    let size = listenook_core::format::shown(listenook_core::format::Shown::Size(
        models.iter().map(Model::size).sum::<u64>() as i64,
    ));
    let failed = move || models.iter().find_map(local::model_error);
    let downloading = move || matches!(state(), ModelState::Downloading(_));
    view()
        .gap_2()
        .child(
            view()
                .flex_row()
                .items_center()
                .gap_3()
                .child(
                    view()
                        .flex_1()
                        .gap_0p5()
                        .child(
                            view()
                                .flex_row()
                                .items_center()
                                .gap_2()
                                .child(text(l(title)).text_sm().font_weight(FontWeight::MEDIUM))
                                .child(when(
                                    move || state() == ModelState::Ready,
                                    || Badge { label: l("Ready"), status: || Status::Success },
                                )),
                        )
                        .child(hint(move || SharedString::from(format!("{} · {size}", tr(about))))),
                )
                .child(
                    when(downloading, move || {
                        button(Variant::Outline, Size::Sm, l("Cancel")).on_press(move || {
                            models.iter().for_each(local::cancel_download);
                        })
                    })
                    .otherwise(move || {
                        when(
                            move || state() == ModelState::Ready,
                            move || {
                                button(Variant::Danger, Size::Sm, l("Remove")).on_press(move || {
                                    confirm_destructive(
                                        format!("{} {}?", tr("Remove"), tr(title)),
                                        tr("The download is deleted. You can download it again later."),
                                        tr("Cancel"),
                                        tr("Remove"),
                                        move || models.iter().for_each(local::remove_model),
                                    );
                                })
                            },
                        )
                        .otherwise(move || {
                            button(Variant::Outline, Size::Sm, move || {
                                tr(if state() == ModelState::Partial { "Resume" } else { "Download" })
                            })
                            .on_press(move || {
                                for model in models {
                                    if local::model_state(model) != ModelState::Ready
                                        && let Some(download) = local::download_model(model)
                                    {
                                        store.run(download);
                                    }
                                }
                            })
                        })
                    }),
                ),
        )
        .child(when(downloading, move || {
            progress_bar(move || match state() {
                ModelState::Downloading(fraction) => Some(fraction as f32),
                _ => None,
            })
        }))
        .child(when(
            move || failed().is_some() && !downloading(),
            move || {
                text(move || error_text(&failed().unwrap_or_default())).text_xs().text_color(|| theme().destructive)
            },
        ))
}

fn on_this_mac() -> impl IntoElement {
    let store = store();
    let ready = |model: &'static Model| local::model_state(model) == ModelState::Ready;
    section(
        l(if cfg!(target_os = "macos") { "On this Mac" } else { "On this device" }),
        panel()
            .child(hint(l("Transcribe without sending audio anywhere. Each model is downloaded once.")))
            .child(model_row(
                "Qwen3",
                "Multilingual; follows a language hint and context terms",
                &[local::catalog::QWEN3],
            ))
            .child(model_row(
                "Qwen3, large",
                "More accurate on difficult audio; several times slower",
                &[local::catalog::QWEN3_LARGE],
            ))
            .child(when(
                move || ready(&local::catalog::QWEN3) && ready(&local::catalog::QWEN3_LARGE),
                move || {
                    field(
                        l("Qwen3 model"),
                        Segmented {
                            options: vec![("0.6b", "Standard"), ("1.7b", "Large")],
                            value: move || {
                                let large = store.setting(|s| {
                                    s.extra.get("qwen3_local_model").and_then(|v| v.as_str()) == Some("1.7b")
                                });
                                if large { "1.7b" } else { "0.6b" }
                            },
                            on_change: move |value: &'static str| {
                                store.update_settings(|s| {
                                    s.extra.insert("qwen3_local_model".into(), value.into());
                                })
                            },
                        },
                    )
                },
            ))
            .child(Separator)
            .child(model_row(
                "Word timing",
                "Needed by Qwen3 for sentence times; highlights each word as it is spoken",
                &[local::catalog::ALIGNER],
            ))
            .child(switch(
                l("Time each word of MOSS transcripts and subtitles"),
                move || store.setting(|s| s.auto_align_transcripts),
                move |on| store.update_settings(|s| s.auto_align_transcripts = on),
            ))
            .child(when(
                || local::offered(listenook_core::TranscriptionProvider::MossLocal),
                || {
                    view().gap_4().child(Separator).child(model_row(
                        "MOSS",
                        "Multilingual, with speaker labels",
                        &[local::catalog::MOSS],
                    ))
                },
            )),
    )
}

fn ai() -> impl IntoElement {
    let store = store();
    let models = signal(Vec::<String>::new());
    let llm_settings = move || store.setting(|s| s.llm_provider_settings.clone());
    let test = move |key: String, status: Signal<SharedString>, verified: Signal<Option<String>>| {
        store.run(async move {
            let settings = store.settings().llm_provider_settings;
            match ai::list_models(&settings, Some(key.clone())).await {
                Ok(found) => {
                    // No model is chosen for the person: an endpoint's list mixes models that
                    // can translate with ones that can't (embeddings, speech, images).
                    let mut said = format!("{} {}", found.len(), tr("models available."));
                    if settings.model.is_empty() && !found.is_empty() {
                        said = format!("{said} {}", tr("Choose one below."));
                    }
                    if !status.try_set(said.into()) {
                        return;
                    }
                    verified.try_set(Some(key));
                    models.try_set(found);
                }
                Err(failure) => drop(status.try_set(error_text(&failure.code))),
            }
        });
    };
    view().gap_6().child(section(
        l("AI provider"),
        panel()
            .child(hint(l("One OpenAI-compatible endpoint shared by translation and AI Briefs. Transcript text is sent to it only when you translate or create a brief.")))
            .child(field(
                l("Provider"),
                select(
                    "Provider",
                    LlmProvider::ALL
                        .iter()
                        .filter(|p| CHATGPT_SIGN_IN || **p != LlmProvider::ChatGpt)
                        .map(|p| (p.as_str().into(), p.label().into()))
                        .collect(),
                    move || SharedString::from(llm_settings().provider.as_str()),
                    move |value| {
                        let provider = LlmProvider::parse(&value);
                        models.set(Vec::new());
                        store.update_settings(|s| {
                            s.llm_provider_settings.provider = provider;
                            if provider != LlmProvider::Custom {
                                s.llm_provider_settings.base_url = provider.base_url().into();
                            }
                            s.llm_provider_settings.model.clear();
                        });
                    },
                )
                .w(px(240.0)),
            ))
            .child(when(move || llm_settings().signs_in(), move || field(l("Account"), chatgpt_account(models))).otherwise(
                move || {
                    view()
                        .gap_4()
                        .child(field(
                            l("Base URL"),
                            settings_input(
                                move || llm_settings().base_url,
                                move |value| store.update_settings(|s| s.llm_provider_settings.base_url = value),
                                "https://api.openai.com/v1",
                            ),
                        ))
                        .child(
                            field(l("API key"), key_field(Secret::Llm, move || llm_settings().is_loopback(), test))
                                .child(when(move || llm_settings().is_loopback(), || {
                                    hint(l("No API key is required for a provider on this computer."))
                                })),
                        )
                },
            ))
            .child(
                field(
                    l("Model"),
                    when(move || !models.with(Vec::is_empty), move || {
                        select(
                            "Model",
                            models.get_untracked().into_iter().map(|m| (m.clone().into(), m.into())).collect(),
                            move || SharedString::from(llm_settings().model),
                            move |value| store.update_settings(|s| s.llm_provider_settings.model = value.to_string()),
                        )
                    })
                    .otherwise(move || {
                        settings_input(
                            move || llm_settings().model,
                            move |value| store.update_settings(|s| s.llm_provider_settings.model = value),
                            "Model ID",
                        )
                    }),
                )
                .child(hint(move || {
                    tr(if llm_settings().signs_in() {
                        "The models your plan offers are listed once you sign in."
                    } else {
                        "Press Test to list the models your endpoint offers."
                    })
                })),
            ),
    ))
}

/// Whether a ChatGPT plan can be signed in to here: the sign-in comes back to a page this
/// computer serves, which phones and tablets do not yet.
const CHATGPT_SIGN_IN: bool = cfg!(any(target_os = "macos", target_os = "windows", target_os = "linux"));

const CHATGPT_SIGN_IN_WORK: &str = "chatgpt:sign-in";

/// Lists the models of the ChatGPT plan signed in, choosing the first when none is chosen.
fn load_chatgpt_models(models: Signal<Vec<String>>, status: Signal<SharedString>) {
    let store = store();
    store.run(async move {
        match chatgpt::models().await {
            Ok(found) => {
                if store.settings().llm_provider_settings.model.is_empty()
                    && let Some(first) = found.first().cloned()
                {
                    store.update_settings(|s| s.llm_provider_settings.model = first);
                }
                models.try_set(found);
            }
            Err(failure) => drop(status.try_set(error_text(&failure.code))),
        }
    });
}

/// The ChatGPT account the AI provider uses: signing in, again, and out.
fn chatgpt_account(models: Signal<Vec<String>>) -> impl IntoElement {
    let store = store();
    let status = signal(SharedString::default());
    let waiting = signal(false);
    let account = move || store.has_key(Secret::ChatGpt).then(Account::saved).flatten();
    if account().is_some() && models.with_untracked(Vec::is_empty) {
        load_chatgpt_models(models, status);
    }
    let sign_in = move || {
        batch(|| {
            waiting.set(true);
            status.set(tr("Finish signing in in your browser…"));
        });
        store.run_for(CHATGPT_SIGN_IN_WORK, async move {
            let signed = chatgpt::sign_in(store.chatgpt_host(), Account::saved(), store.lang()).await;
            waiting.try_set(false);
            let saved = signed.map_err(|failure| failure.code).and_then(|account| {
                store.write_key(Secret::ChatGpt, &account.secret()).map_err(|error| {
                    log::error!("keeping the ChatGPT sign-in: {error}");
                    "chatgpt_keychain".to_owned()
                })
            });
            match saved {
                Ok(()) => {
                    status.try_set(SharedString::default());
                    load_chatgpt_models(models, status);
                }
                Err(code) => drop(status.try_set(error_text(&code))),
            }
        });
    };
    let cancel = move || {
        store.cancel_work(CHATGPT_SIGN_IN_WORK);
        batch(|| {
            waiting.set(false);
            status.set(SharedString::default());
        });
    };
    let sign_out = move || {
        confirm_destructive(
            tr("Sign out of ChatGPT?"),
            tr("Translation and AI Briefs stop working until you sign in again."),
            tr("Cancel"),
            tr("Sign Out"),
            move || {
                let Some(account) = Account::saved() else {
                    return;
                };
                if store.write_key(Secret::ChatGpt, "").is_ok() {
                    models.set(Vec::new());
                    status.set(SharedString::default());
                    store.run(chatgpt::sign_out(account));
                }
            },
        );
    };
    view()
        .gap_2()
        .child(view().flex_row().flex_wrap().items_center().gap_2().child(
            when(waiting, move || button(Variant::Outline, Size::Md, l("Cancel")).on_press(cancel)).otherwise(
                move || {
                    when(
                        move || account().is_some(),
                        move || {
                            view()
                                .flex_row()
                                .gap_2()
                                .child(button(Variant::Outline, Size::Md, l("Sign In Again")).on_press(sign_in))
                                .child(button(Variant::Danger, Size::Md, l("Sign Out")).on_press(sign_out))
                        },
                    )
                    .otherwise(move || button(Variant::Default, Size::Md, l("Sign in with ChatGPT")).on_press(sign_in))
                },
            ),
        ))
        .child(
            view()
                .flex_row()
                .items_center()
                .gap_2()
                .child(
                    when(move || account().is_some(), || Badge { label: l("Signed in"), status: || Status::Success })
                        .otherwise(|| Badge { label: l("Setup required"), status: || Status::Warning }),
                )
                .child(hint(move || {
                    let said = status.get();
                    match account() {
                        Some(account) if said.is_empty() => SharedString::from(account.email().to_owned()),
                        _ => said,
                    }
                })),
        )
        .child(hint(l("Uses your ChatGPT Plus or Pro plan instead of an API key. Your browser opens to sign in.")))
}

fn settings_input(
    value: impl Fn() -> String + 'static,
    set: impl Fn(String) + 'static,
    placeholder: &'static str,
) -> impl IntoElement {
    BoundFieldWith {
        value,
        set,
        placeholder: move || tr(placeholder),
        more: |input: Input| input.auto_capitalize(AutoCapitalize::None).auto_correct(false),
    }
}

fn shortcuts() -> impl IntoElement {
    let group = |title: &'static str, rows: Vec<(&'static str, &'static str)>| {
        section(
            l(title),
            card().children(rows.into_iter().enumerate().map(|(index, (keystroke, action))| {
                view()
                    .flex_row()
                    .items_center()
                    .justify_between()
                    .px_4()
                    .py_2()
                    .when(index > 0, |row| row.border_t_1().border_color(|| theme().border))
                    .child(text(l(action)).text_sm().text_color(|| theme().foreground))
                    .child(KeyCap { keystroke })
            })),
        )
    };
    let store = store();
    let anywhere = move || {
        section(
        l("From any app"),
        panel()
            .child(switch(l(if cfg!(target_os = "macos") { "Play or pause with ⌃⌥Space" } else { "Play or pause with Ctrl+Alt+Space" }), move || store.setting(|s| s.extra.get("global_play_pause").and_then(|v| v.as_bool()).unwrap_or(false)), move |on| store.update_settings(|s| drop(s.extra.insert("global_play_pause".into(), on.into())))))
            .child(hint(l("Works while another app is in front. Off unless you turn it on: it takes the keystroke from every app."))),
    )
    };
    view()
        .gap_6()
        .child(when(|| !crate::platform::is_phone(), anywhere))
        .child(group("Application", {
            let mut keys = vec![
                ("mod+1", "Home"),
                ("mod+2", "Library"),
                ("mod+3", "Podcasts"),
                ("mod+,", "Settings"),
                ("mod+b", "Show or hide the sidebar"),
                ("mod+o", "Add media"),
            ];
            if super::capture::offered() {
                keys.push(("mod+shift+r", "Record what’s playing, or stop recording"));
            }
            keys.extend([("mod+shift+o", "Open video"), ("mod+enter", "Transcribe everything that is ready")]);
            keys
        }))
        .child(group(
            "Playback",
            vec![
                ("space", "Play or pause"),
                ("left", "Previous sentence"),
                ("right", "Next sentence"),
                ("r", "Repeat the sentence while held"),
                ("s", "Reveal current sentence"),
                ("e", "Edit current sentence"),
            ],
        ))
        .child(group(
            "Transcript",
            vec![
                ("mod+f", "Search transcript"),
                ("mod+b", "Highlight the selected words"),
                ("mod+enter", "Save an edit, or check your answer"),
                ("mod+r", "Play the sentence again while typing"),
                ("mod+z", "Undo the last sentence change"),
                ("escape", "Cancel an edit, close search, or go back"),
            ],
        ))
}

/// What says the system keeps Listenook's notifications from showing while the app wants them,
/// with the way to the app's page in the system's settings where there is one (iOS, Android).
/// Looked at again each time the app comes back, as the user may have just changed it there.
fn notifications_turned_off() -> impl IntoElement {
    let store = store();
    let (refused, can_open) = (signal(false), signal(false));
    effect(move || {
        let wanted = store.setting(|s| s.extra.get("notify_when_done").and_then(|v| v.as_bool()).unwrap_or(true));
        if !store.focused() {
            return;
        }
        if !wanted {
            refused.set(false);
            return;
        }
        store.run(async move {
            let denied = notification_permission().await == nsh_core::notifications::NotificationPermission::Denied;
            let _ = refused.try_set(denied);
            if denied {
                let _ = can_open.try_set(nsh_core::mobile::app_settings_available().await);
            }
        });
    });
    when(
        move || refused.get(),
        move || {
            view()
                .flex_row()
                .items_center()
                .justify_between()
                .gap_3()
                .child(hint(l("Notifications for Listenook are turned off in the system’s settings.")).flex_1())
                .child(when(
                    move || can_open.get(),
                    || {
                        button(Variant::Outline, Size::Sm, l("Open Settings"))
                            .on_press(|| drop(nsh_core::mobile::open_app_settings()))
                    },
                ))
        },
    )
}

fn about() -> impl IntoElement {
    let store = store();
    view().gap_6().child(section(
        move || SharedString::from(store.lang().app_name()),
        panel().child(
            view()
                .flex_row()
                .items_center()
                .justify_between()
                .gap_3()
                .child(
                    text(move || SharedString::from(format!("{} {}", tr("Version"), shown_version())))
                        .flex_1()
                        .text_sm()
                        .text_color(|| theme().foreground),
                )
                .child(when(
                    || updater::SELF_UPDATING,
                    || button(Variant::Default, Size::Md, l("Check for updates")).on_press(updater::check),
                )),
        ),
    ))
    .child(section(
        l("Privacy"),
        panel().child(
            text(l("Listenook has no backend. Cloud transcription sends media directly to the provider you choose when you start a job; translation and AI Briefs send transcript text to your AI endpoint. API keys are kept in the system’s secure storage, or on Android and Linux in a file only Listenook can read. Transcripts and settings stay on this device."))
                .text_sm()
                .text_color(|| theme().muted_foreground),
        ),
    ))
}

fn choose_watched_folder() {
    let answer = pick_paths(nsh_core::file_dialog::OpenDialog::folders());
    store().run(async move {
        if let Ok(Some(paths)) = answer.await
            && let Some(folder) = paths.first().and_then(|path| path.to_str())
        {
            MonitorState::get().act(crate::state::monitor::MonitorAction::WatchFolder(folder));
        }
    });
}
