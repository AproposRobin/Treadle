#!/bin/bash
# Builds bin/linux64/libtreadlehost.so, the Treadle native host (SDL2 + OpenGL3 + Dear ImGui + imnodes + cimgui +
# cimnodes + host/treadlehost.cpp), the Linux counterpart of build_windows.ps1. TreadleNative links it with
# -ltreadlehost and an rpath to this folder (Native/BeefProj.toml, Configs.*.Linux64). The host's own exports
# carry the th_ prefix (Native/src/ImNodes.bf binds them); the window icon comes from host/treadle_icon.h.
#
# Requires: g++ (or CXX=clang++), the SDL2 dev package (libsdl2-dev), OpenGL headers (libgl1-mesa-dev).
# Optional: ccache (used when found), JOBS (parallel compiles, default 6), NICE (default 15).
# Reproducible: the same sources, compiler and SDL2 headers give the same bytes (__FILE__ paths relative to the
# repository, a fixed per-file random seed, no date or time macros, a content-hash build id). The script prints
# the sha256 of the library and compares it with packaging/host-sha256.txt; record the new hash there when the
# host changes (the recorded one is from the WSL Ubuntu toolchain of docs/Linux-Development.md).
# Usage: Native/build_linux.sh          incremental (only changed sources are recompiled)
#        Native/build_linux.sh clean    removes obj/linux64 first
set -e
cd "$(dirname "$0")"
command -v sdl2-config >/dev/null || { echo "sdl2-config not found: install libsdl2-dev"; exit 1; }
: "${CXX:=g++}"
: "${JOBS:=6}"
: "${NICE:=15}"
CC_WRAP=""
command -v ccache >/dev/null && CC_WRAP=ccache
[ "${1:-}" = "clean" ] && rm -rf obj/linux64
T=third_party
OUT=bin/linux64
mkdir -p $OUT obj/linux64
SRCS="$T/cimgui/imgui/imgui.cpp $T/cimgui/imgui/imgui_draw.cpp $T/cimgui/imgui/imgui_tables.cpp $T/cimgui/imgui/imgui_widgets.cpp $T/cimgui/imgui/imgui_demo.cpp \
      $T/cimgui/imgui/imgui_impl_sdl2.cpp $T/cimgui/imgui/imgui_impl_opengl3.cpp \
      $T/cimgui/cimgui.cpp $T/cimnodes/imnodes/imnodes.cpp $T/cimnodes/cimnodes.cpp host/treadlehost.cpp"
FLAGS="-ffile-prefix-map=$(cd .. && pwd)=. -O2 -DNDEBUG -fPIC -fvisibility=hidden -DIMNODES_NAMESPACE=imnodes -DIMGUI_IMPL_API= -I$T/cimgui/imgui -I$T/cimgui -I$T/cimnodes/imnodes $(sdl2-config --cflags)"
export CXX CC_WRAP FLAGS NICE
OBJS=""
TODO=""
for s in $SRCS; do
  o=obj/linux64/$(basename ${s%.cpp}).o
  if [ ! -f $o ] || [ $s -nt $o ]; then TODO="$TODO $s"; fi
  OBJS="$OBJS $o"
done
if [ -n "$TODO" ]; then
  printf '%s\n' $TODO | xargs -P "$JOBS" -I{} sh -c 'b=$(basename {} .cpp); o=obj/linux64/$b.o; echo "  CXX {}"; nice -n $NICE $CC_WRAP $CXX $FLAGS -frandom-seed=$b -c {} -o $o'
fi
# RUNPATH $ORIGIN: a package ships libSDL2-2.0.so.0 next to libtreadlehost.so (scripts/package-linux.sh); without one
# there (a source build) the loader falls back to the system's SDL2. --build-id=sha1 hashes the content (no time).
$CXX -shared -o $OUT/libtreadlehost.so $OBJS $(sdl2-config --libs) -lGL -ldl -Wl,-rpath,'$ORIGIN' -Wl,--build-id=sha1
echo "Built $OUT/libtreadlehost.so"
# The sha256 of what was built, against the recorded one (packaging/host-sha256.txt, sha256sum format).
H=$(sha256sum $OUT/libtreadlehost.so | cut -d' ' -f1)
R=$(tr -d '\r' < ../packaging/host-sha256.txt 2>/dev/null | grep -E ' [ *]?Native/bin/linux64/libtreadlehost.so$' | cut -d' ' -f1)  # CR-tolerant: a Windows checkout has CRLF
if [ -z "$R" ]; then NOTE="not recorded"; elif [ "$R" = "$H" ]; then NOTE="matches packaging/host-sha256.txt"; else NOTE="DIFFERS from packaging/host-sha256.txt"; fi
echo "$H  Native/bin/linux64/libtreadlehost.so  ($NOTE)"
