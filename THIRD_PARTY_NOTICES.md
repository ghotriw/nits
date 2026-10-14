# Third-Party Notices

Nits is licensed under the [MIT License](LICENSE), except for the parts listed below.

## Bundled libraries

`Nits.app` ships these as dynamic libraries in `Contents/Frameworks`. Their license texts and
build details are in `Contents/Resources/ThirdPartyLicenses`.

| Library | License | Source |
|---|---|---|
| [FFmpeg](https://ffmpeg.org) (libavformat, libavcodec, libavutil, libswresample, libswscale) | LGPL-2.1-or-later | Unmodified upstream release; the exact source archive is attached to the matching `deps-v*` [GitHub release](https://github.com/ghotriw/nits/releases). Built by [`scripts/build_dependencies.sh`](scripts/build_dependencies.sh). |
| [dav1d](https://code.videolan.org/videolan/dav1d) | BSD-2-Clause | Same as above. |

FFmpeg is built without `--enable-gpl`, `--enable-version3` or `--enable-nonfree`. Being dynamically
linked, the libraries can be replaced with your own builds of the same major versions (re-sign the
app afterwards with `codesign --force --deep -s - Nits.app`).

## Code derived from third-party sources

| File | Derived from | License |
|---|---|---|
| [`Sources/NitsCore/Video/BT2390ToneMapping.metal`](Sources/NitsCore/Video/BT2390ToneMapping.metal) | [mpv](https://mpv.io) `video/out/gpu/video_shaders.c` (BT.2390 tone mapping and desaturation) | LGPL-2.1-or-later |

The full LGPL-2.1 text ships as `ThirdPartyLicenses/ffmpeg/COPYING.LGPLv2.1` and is available at
<https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html>.
