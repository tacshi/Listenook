use std::fs::File;

use listenook_core::media::container;

#[test]
#[ignore = "needs MKV and MP4"]
fn a_matroska_file_is_put_into_an_mp4_file() {
    let (input, output) = (std::env::var("MKV").unwrap(), std::env::var("MP4").unwrap());
    let device = container::Device { shows_vp9: true, shows_av1: true, converts_av1: false };
    println!("plan: {:?}", container::plan(std::path::Path::new(&input), device));
    let (input, output) = (File::open(&input).unwrap(), File::create(&output).unwrap());
    let result = container::mkv_to_mp4(input, output, container::Pictures::Copy, &mut |_| true);
    println!("{result:?}");
}

#[test]
#[ignore = "needs AVI and SOUND"]
fn an_avi_files_sound_is_taken_out() {
    let (input, output) = (std::env::var("AVI").unwrap(), std::env::var("SOUND").unwrap());
    let kind = container::avi_sound(File::open(&input).unwrap(), File::create(&output).unwrap()).unwrap();
    std::fs::rename(&output, format!("{output}.{}", kind.extension())).unwrap();
    println!("{kind:?}");
}

#[test]
#[ignore = "needs SUBS"]
fn subtitle_tracks_are_read() {
    let path = std::env::var("SUBS").unwrap();
    let tracks = container::subtitles_in(std::path::Path::new(&path));
    for track in &tracks {
        println!("{}: {} cues; first {:?}", track.label, track.cues.len(), track.cues.first());
    }
    assert!(!tracks.is_empty());
}
