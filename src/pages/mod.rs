//! The app's pages: the Library, Podcasts, the reader that opens over
//! either, and the Settings dialog.

mod dialogs;
mod library;
mod player;
mod podcast;
mod settings;
mod sync;
mod workspace;

pub(crate) use dialogs::subtitle_choice_dialog;
pub(crate) use library::library;
pub(crate) use player::{VIDEO_EXTENSIONS, is_video, open_player, player};
pub(crate) use podcast::{podcasts_page as podcasts, show_screen as podcast_show};
pub(crate) use settings::settings_dialog;
pub(crate) use sync::{sync_dialog, sync_request_dialog};
pub(crate) use workspace::reader;
