#!/bin/bash
# Build the two separate command-line programs from the pinned upstream source.
set -euo pipefail
cd "$1"
./configure --disable-autodetect --disable-gpl --disable-nonfree \
    --disable-version3 --disable-doc --disable-debug --disable-ffplay \
    --disable-network --disable-shared --enable-static --cc=clang \
    --enable-zlib --enable-bzlib --enable-iconv \
    --extra-libs=-liconv \
    --enable-audiotoolbox --enable-videotoolbox --enable-coreimage \
    > configure-dumptruck.log 2>&1
make -j8 ffmpeg ffprobe > build-dumptruck.log 2>&1
