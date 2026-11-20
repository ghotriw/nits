#pragma once
// One module for FFmpeg on every platform. macOS: the headers of the system library (CFFmpegSystem: the bundled prefix or
// Homebrew, found by pkg-config); iOS: the headers of the xcframeworks, which hold each library as a framework
// of its name, so `<libavformat/avformat.h>` is a framework include. Linking comes from the dependencies of the target.
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/hdr_dynamic_metadata.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
