# libmpv and FFmpeg

Listenook plays recordings and videos with [libmpv](https://mpv.io) and [FFmpeg](https://ffmpeg.org),
built without their GPL parts, under the GNU Lesser General Public License: mpv under version 2.1
or later, FFmpeg under version 2.1 or later, or version 3 or later where it is built with
`--enable-version3`. See `LGPL-2.1.txt`, `LGPL-3.0.txt` and `GPL-3.0.txt` (which version 3 of the
LGPL builds on), next to this file.

Listenook's own source code is public at https://github.com/tacshi/Listenook, so it can be rebuilt
and relinked with a modified libmpv or FFmpeg. The exact builds Listenook uses are listed, with
their checksums, in `scripts/mpv-libraries.txt` there.

## Builds

- **macOS and iOS:** [MPVKit](https://github.com/mpvkit/MPVKit) 1.0.0 (mpv 0.41.0; FFmpeg under LGPL 3),
  its LGPL build, linked statically. Its build scripts and the sources they use are in that
  repository. It also includes libass (ISC), FreeType (FreeType License), HarfBuzz (MIT), FriBidi
  (LGPL 2.1), libplacebo (LGPL 2.1), dav1d (BSD 2-Clause), MoltenVK (Apache 2.0), shaderc
  (Apache 2.0), Little CMS (MIT), OpenSSL (Apache 2.0), GnuTLS (LGPL 2.1), Nettle and GMP
  (LGPL 3), libbluray (LGPL 2.1), uchardet (MPL 1.1), LuaJIT (MIT), libunibreak (zlib),
  uavs3d (BSD 3-Clause) and libdovi (MIT).
- **Windows:** `libmpv-2.dll` from [mpv-winbuild](https://github.com/zhongfly/mpv-winbuild)'s LGPL
  build of 2026-11-25 (mpv d32c910be6, FFmpeg c81e35cf2), loaded from the app's folder.
- **Linux:** the system's libmpv, from the distribution.
- **Android:** libmpv-android's LGPL build (mpv 0.42.0 with `-Dgpl=false`, FFmpeg 9.0.2 with
  `--enable-version3`), as shared libraries in the app.
