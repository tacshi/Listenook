# FFmpeg component notice

MeowSTT does not distribute or launch the standalone `ffmpeg` and `ffprobe`
command-line programs. Playback, probing, and PCM extraction use the libmpv
native library supplied by `media_kit_libs_video`. That libmpv build includes
FFmpeg components and other codecs internally.

- media_kit: https://github.com/media-kit/media-kit
- mpv: https://mpv.io/
- FFmpeg source and build instructions: https://ffmpeg.org/download.html
- FFmpeg legal information: https://ffmpeg.org/legal.html
