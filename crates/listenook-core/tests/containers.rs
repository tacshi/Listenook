//! Repackaging real files: `MKV=<in.mkv> MP4=<out.mp4>` and/or
//! `AVI=<in.avi> SOUND=<out without extension>`, with `-- --ignored`.

use std::fs::File;

use listenook_core::container;

#[test]
#[ignore = "needs MKV and MP4"]
fn a_matroska_file_is_put_into_an_mp4_file() {
    let (input, output) = (std::env::var("MKV").unwrap(), std::env::var("MP4").unwrap());
    println!("fits: {}", container::mkv_fits_mp4(File::open(&input).unwrap()));
    let result = container::mkv_to_mp4(|| File::open(&input), File::create(&output).unwrap());
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
    let tracks = if path.ends_with(".mkv") {
        container::mkv_subtitles(File::open(&path).unwrap())
    } else {
        let size = std::fs::metadata(&path).unwrap().len();
        container::mp4_subtitles(File::open(&path).unwrap(), size)
    };
    for track in &tracks {
        println!("{}: {} cues; first {:?}", track.label, track.cues.len(), track.cues.first());
    }
    assert!(!tracks.is_empty());
}
