#!/bin/bash
# Builds the editor on Linux (ReleasePackage: Release without the self tests) and assembles a self-contained
# Treadle folder, its tarball and the tarball's SHA-256 (docs/Releasing.md, "Linux package";
# docs/Linux-Development.md, "Package").
#
# Output: dist/Treadle-<version>-linux-x64/ and dist/Treadle-<version>-linux-x64.tar.gz (+ .tar.gz.sha256).
# The tarball holds that one folder. Layout:
#   treadle, libtreadlehost.so, libSDL2-2.0.so.0   the editor, its native host and the SDL2 the host loads
#   treadle.png, install-desktop.sh                  the icon (256 px) and the script that adds a menu entry
#   assets/fonts/                                    the icon font and its licence
#   core/                                            the core library (TreadleCore/core), found next to the exe
#   tools/runtime/                                   the C runtime sources every program is built with
#   tools/llvm/                                      trimmed LLVM 22 (packaging/llvm-files-linux.txt): clang, lld,
#                                                    lldb-dap, libclang.so, builtin headers, compiler-rt
#   samples/                                         the sample projects of packaging/samples.txt and their index
#   docs/                                            the user-facing pages (and docs/images when present)
#   LICENSE, NOTICE, THIRD_PARTY.md, THIRD_PARTY/, VERSION.txt
#
# Run on x86-64 Linux (Ubuntu 26.04 under WSL2 is what it is made and proven on) with the packages of
# docs/Linux-Development.md (clang-22 lld-22 lldb-22 libclang-22-dev libsdl2-dev ...) and BeefBuild. The version is
# VERSION.txt, the same file scripts/package.ps1 reads; it must agree with TreadleInfo (CommandLine.bf) and
# the packaged exe's --version must print it.
#
# Usage: scripts/package-linux.sh [options]
#   --no-build             package the existing build/ReleasePackage_Linux64 (--verify uses build/Release_Linux64)
#   --llvm <root>          the LLVM 22 root to trim from (default TREADLE_LLVM, else /usr/lib/llvm-22)
#   --no-debugger          leave lldb-dap and what only it needs out ("[debug]" lines of the file list)
#   --out <folder>         the folder to assemble (default dist/Treadle-<version>-linux-x64)
#   --dist <folder>        where the tarball and its .sha256 go (default dist/)
#   --trim-toolchain-to <folder>   only copy the trimmed toolchain there and print its size
#   --verify               unpack the tarball and prove it works from the unpacked copy alone
#   --verify-dir <folder>  where --verify unpacks (default ${TMPDIR:-/tmp}/treadle-pkg-verify-<stamp>)
# Environment: BEEFBUILD (else BeefBuild on PATH, else ~/beef/IDE/dist/BeefBuild), NICE (default 10).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NO_BUILD=0; LLVM_SRC=""; DEBUGGER=1; OUT=""; DIST=""; TRIM_TO=""; VERIFY=0; VERIFY_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) NO_BUILD=1 ;;
    --llvm) LLVM_SRC="$2"; shift ;;
    --no-debugger) DEBUGGER=0 ;;
    --out) OUT="$2"; shift ;;
    --dist) DIST="$2"; shift ;;
    --trim-toolchain-to) TRIM_TO="$2"; shift ;;
    --verify) VERIFY=1 ;;
    --verify-dir) VERIFY_DIR="$2"; shift ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "unknown option $1 (--help)"; exit 2 ;;
  esac
  shift
done
: "${NICE:=10}"
die() { echo "package-linux: $*" >&2; exit 1; }
mb() { du -sb "$1" | awk '{ printf "%.1f MB", $1 / 1048576 }'; }

# ------------------------------------------------------------------------------------------- toolchain

if [ -z "$LLVM_SRC" ]; then LLVM_SRC="${TREADLE_LLVM:-/usr/lib/llvm-22}"; fi
[ -x "$LLVM_SRC/bin/clang" ] || die "no LLVM at $LLVM_SRC (bin/clang): install clang-22 lld-22 lldb-22 libclang-22-dev (docs/Linux-Development.md) or pass --llvm"
LIST="$ROOT/packaging/llvm-files-linux.txt"
CFG="$ROOT/packaging/x86_64-pc-linux-gnu.cfg"

# Copies the subset of the LLVM root named in packaging/llvm-files-linux.txt into $1. Prints the system
# libraries it took (absolute entries) to stdout of the caller through SYSLIBS.
SYSLIBS=()
copy_toolchain() {
  local dst="$1" line debug rel
  local -a excludes=()
  mkdir -p "$dst/bin" "$dst/lib"
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$line" ] || [ "${line:0:1}" = "#" ] && continue
    debug=0
    if [[ "$line" == *"[debug]" ]]; then debug=1; line="$(echo "${line%\[debug\]}" | sed 's/[[:space:]]*$//')"; fi
    [ $debug = 1 ] && [ $DEBUGGER = 0 ] && continue
    if [ "${line:0:1}" = "!" ]; then excludes+=("${line:1}"); continue; fi
    if [[ "$line" == *" -> "* ]]; then
      rel="${line%% -> *}"
      mkdir -p "$dst/$(dirname "$rel")"
      ln -sfn "${line##* -> }" "$dst/$rel"
      continue
    fi
    if [ "${line:0:1}" = "/" ]; then
      [ -e "$line" ] || die "system library missing: $line (docs/Linux-Development.md packages)"
      cp -L "$line" "$dst/lib/$(basename "$line")"
      SYSLIBS+=("$line")
      continue
    fi
    [ -e "$LLVM_SRC/${line%/}" ] || die "toolchain entry missing in $LLVM_SRC: $line"
    if [[ "$line" == */ ]]; then
      mkdir -p "$dst/$line"
      cp -rL "$LLVM_SRC/$line." "$dst/$line"
    else
      mkdir -p "$dst/$(dirname "$line")"
      cp -L "$LLVM_SRC/$line" "$dst/$line"
    fi
  done < "$LIST"
  local ex
  for ex in "${excludes[@]+"${excludes[@]}"}"; do rm -rf "${dst:?}/$ex"; done
  # Debian's liblldb starts the debug server by its versioned name (lldb-server-22.1.2): keep the distribution's
  # versioned links to lldb-server next to it.
  if [ $DEBUGGER = 1 ]; then
    local l
    for l in "$LLVM_SRC"/bin/lldb-server-*; do
      [ -L "$l" ] && [ "$(readlink "$l")" = lldb-server ] && ln -sfn lldb-server "$dst/bin/$(basename "$l")"
    done
  fi
  install -m 644 "$CFG" "$dst/bin/"
  # The distribution's LLVM licence (Apache-2.0 with LLVM Exceptions).
  cp "$ROOT/THIRD_PARTY/LLVM-LICENSE.txt" "$dst/LICENSE.TXT"
  # Every shipped binary must find its libraries (in tools/llvm/lib or the system).
  local f missing
  for f in "$dst"/bin/* "$dst"/lib/*.so*; do
    [ -L "$f" ] && continue
    missing="$(ldd "$f" 2>/dev/null | grep "not found" || true)"
    [ -z "$missing" ] || die "$f: $missing"
  done
}

if [ -n "$TRIM_TO" ]; then
  if [ -d "$TRIM_TO" ] && [ -n "$(ls -A "$TRIM_TO")" ]; then die "$TRIM_TO is not empty"; fi
  copy_toolchain "$TRIM_TO"
  echo "Trimmed toolchain from $LLVM_SRC"
  echo "  $TRIM_TO: $(mb "$TRIM_TO")"
  exit 0
fi

# ------------------------------------------------------------------------------------------- version

[ -f "$ROOT/VERSION.txt" ] || die "VERSION.txt missing at the repository root"
FULL="$(head -1 "$ROOT/VERSION.txt" | tr -d '\r[:space:]')"
[[ "$FULL" =~ ^([0-9]+\.[0-9]+\.[0-9]+)(-([a-z0-9.]+))?$ ]] || die "VERSION.txt says '$FULL', expected MAJOR.MINOR.PATCH[-channel]"
INFO="$ROOT/TreadleCore/src/Document/CommandLine.bf"
CODE_V="$(grep -o 'public const String Version = "[^"]*";' "$INFO" | sed 's/.*= "\(.*\)";/\1/')"
CODE_C="$(grep -o 'public const String Channel = "[^"]*";' "$INFO" | sed 's/.*= "\(.*\)";/\1/')"
CODE_FULL="$CODE_V${CODE_C:+-$CODE_C}"
[ "$CODE_FULL" = "$FULL" ] || die "VERSION.txt says $FULL, TreadleInfo (CommandLine.bf) says $CODE_FULL: change both"
NAME="Treadle-$FULL-linux-x64"

for f in LICENSE NOTICE THIRD_PARTY.md; do [ -f "$ROOT/$f" ] || die "missing required file: $f"; done
for f in LLVM-LICENSE.txt Python-LICENSE.txt SDL2-LICENSE.txt; do [ -f "$ROOT/THIRD_PARTY/$f" ] || die "missing THIRD_PARTY/$f"; done
# The samples that ship (packaging/samples.txt): each needs a project file and a README.md. A folder with both that
# the list does not name ships too, with a warning; "!name" lines keep folders out.
SAMPLES=(); NOT_SHIPPED=" "
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  name="$(echo "${line%%|*}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$name" ] || [ "${name:0:1}" = "#" ] && continue
  if [ "${name:0:1}" = "!" ]; then NOT_SHIPPED+="${name:1} "; continue; fi
  sdir="$ROOT/TreadleCore/samples/$name"
  [ -d "$sdir" ] || die "packaging/samples.txt names $name, which is not in TreadleCore/samples"
  ls "$sdir"/*.tproj >/dev/null 2>&1 || die "sample $name has no .tproj"
  [ -f "$sdir/README.md" ] || die "sample $name has no README.md"
  SAMPLES+=("$name")
done < "$ROOT/packaging/samples.txt"
for d in "$ROOT"/TreadleCore/samples/*/; do
  n="$(basename "$d")"
  [[ " ${SAMPLES[*]} " == *" $n "* ]] && continue
  [[ "$NOT_SHIPPED" == *" $n "* ]] && continue
  if ls "$d"*.tproj >/dev/null 2>&1 && [ -f "$d/README.md" ]; then
    echo "warning: sample $n is not in packaging/samples.txt: it ships; add its line (or a !$n line)"
    SAMPLES+=("$n")
  fi
done
[ -f "$ROOT/TreadleCore/samples/README.md" ] || die "TreadleCore/samples/README.md (the samples index) is missing"
DOCS="Getting-Started.md Language-Guide.md Core-Library.md C-Import.md Debugging.md Keyboard.md Linux.md Performance.md Known-Issues.md"

# ------------------------------------------------------------------------------------------- build

# The package is built in the ReleasePackage configuration: Release settings without the TREADLE_SELFTEST define,
# so the developer self tests are not in the shipped exe (docs/Releasing.md, "Self tests and the package build").
# --verify also builds Release (the same code with the self tests) to compare sizes and to run the debugger self
# test in the package's layout.
REL="$ROOT/build/ReleasePackage_Linux64/TreadleEditor"
TEST_REL="$ROOT/build/Release_Linux64/TreadleEditor"
if [ $NO_BUILD = 0 ]; then
  # One BeefBuild at a time on this machine (another checkout may be building).
  while pgrep -x BeefBuild >/dev/null; do echo "waiting for another BeefBuild to finish"; sleep 15; done
  rm -f "$REL/treadle"
  NICE=$NICE bash "$ROOT/scripts/build-linux.sh" ReleasePackage none || die "the ReleasePackage build failed"
  if [ $VERIFY = 1 ]; then NICE=$NICE bash "$ROOT/scripts/build-linux.sh" Release none || die "the Release build failed"; fi
fi
for f in treadle libtreadlehost.so; do [ -f "$REL/$f" ] || die "missing build output: $REL/$f"; done

# ------------------------------------------------------------------------------------------- assemble

[ -n "$OUT" ] || OUT="$ROOT/dist/$NAME"
[ -n "$DIST" ] || DIST="$ROOT/dist"
if [ -d "$OUT" ] && [ -n "$(ls -A "$OUT")" ]; then
  if [ -f "$OUT/VERSION.txt" ] && [ -f "$OUT/treadle" ]; then
    echo "Emptying the earlier package folder $OUT"
    rm -rf "${OUT:?}"/* "${OUT:?}"/.[!.]* 2>/dev/null || true
  else die "$OUT is not empty and is not an earlier package folder (no VERSION.txt and treadle)"; fi
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

cp "$REL/treadle" "$REL/libtreadlehost.so" "$OUT/"
# No DWARF in the shipped binaries (as no .pdb ships on Windows); the symbol tables stay for crash backtraces.
strip --strip-debug "$OUT/treadle" "$OUT/libtreadlehost.so"
# SDL2 next to the host (libtreadlehost.so has RUNPATH $ORIGIN, Native/build_linux.sh); its own dependencies (X11,
# Wayland, audio) are the desktop's.
SDL="$(ldd "$REL/libtreadlehost.so" | awk '/libSDL2-2.0.so.0/ { print $3 }')"
[ -n "$SDL" ] && [ -f "$SDL" ] || die "libtreadlehost.so does not resolve libSDL2-2.0.so.0 (install libsdl2-dev)"
readelf -d "$REL/libtreadlehost.so" | grep -q 'RUNPATH.*\$ORIGIN' || die "libtreadlehost.so has no RUNPATH \$ORIGIN: rebuild it with Native/build_linux.sh"
cp -L "$SDL" "$OUT/libSDL2-2.0.so.0"
# The icon and a per-user application-menu entry (install-desktop.sh writes treadle.desktop with this folder's path).
cp "$ROOT/packaging/treadle-icon/Treadle-256.png" "$OUT/treadle.png"
cp "$ROOT/packaging/linux/install-desktop.sh" "$OUT/install-desktop.sh"
chmod +x "$OUT/install-desktop.sh"
mkdir -p "$OUT/assets/fonts"
cp -r "$ROOT/TreadleEditor/assets/fonts/." "$OUT/assets/fonts/"
cp -r "$ROOT/TreadleCore/core" "$OUT/core"
mkdir -p "$OUT/tools/runtime"
cp "$ROOT/tools/runtime/treadle_rt.c" "$ROOT/tools/runtime/treadle_rt.h" "$OUT/tools/runtime/"

echo "== Toolchain subset from $LLVM_SRC"
copy_toolchain "$OUT/tools/llvm"

# The samples (packaging/samples.txt) and their index. A sample built or run in this checkout has a build folder and
# may have written files next to its input: they do not ship. Paths that lead out of the source tree's sample are
# rewritten for the package's layout: the SDL samples' Linux sets link the package's own libSDL2-2.0.so.0
# (../../libSDL2-2.0.so.0 from samples/<name>; the program runs with the system's SDL2, or LD_LIBRARY_PATH set to
# the package folder), their Windows sets take ../../tools/SDL2 as the Windows package does, and m2-frontend's probe
# header is copied beside its set.
mkdir -p "$OUT/samples"
cp "$ROOT/TreadleCore/samples/README.md" "$OUT/samples/README.md"
for s in "${SAMPLES[@]}"; do
  cp -r "$ROOT/TreadleCore/samples/$s" "$OUT/samples/$s"
  rm -rf "$OUT/samples/$s/build" "$OUT/samples/$s/m3-files-out"
  find "$OUT/samples/$s" -name '*.pretty.json' -delete
  while IFS= read -r ci; do
    if grep -q '\.\./\.\./\.\./\.\./tools/probe/headers/small\.h' "$ci"; then
      sed -i 's#\.\./\.\./\.\./\.\./tools/probe/headers/small\.h#small.h#' "$ci"
      cp "$ROOT/tools/probe/headers/small.h" "$(dirname "$ci")/small.h"
    fi
    sed -i 's#\${TREADLE_SDL2:-\.\./\.\./\.\./tools/SDL2-2\.32\.10}#${TREADLE_SDL2:-../../tools/SDL2}#g' "$ci"
    case "$ci" in *.linux.cimport) sed -i 's#^\(\s*\)lib SDL2$#\1lib ../../libSDL2-2.0.so.0#' "$ci" ;; esac
    if grep -q '\.\./\.\./\.\./' "$ci"; then die "$ci still names a path outside the package"; fi
  done < <(find "$OUT/samples/$s" -name '*.cimport')
done
grep -q 'lib \.\./\.\./libSDL2-2\.0\.so\.0' "$OUT/samples/m2-sdl/sdl2.linux.cimport" || die "samples/m2-sdl/sdl2.linux.cimport was not rewritten to the package's libSDL2"
mkdir -p "$OUT/docs"
for d in $DOCS; do
  if [ -f "$ROOT/docs/$d" ]; then cp "$ROOT/docs/$d" "$OUT/docs/$d"
  elif [ "$d" = Getting-Started.md ]; then die "docs/Getting-Started.md is missing"
  else echo "warning: docs/$d is not in this checkout; not shipped"; fi
done
[ -d "$ROOT/docs/images" ] && cp -r "$ROOT/docs/images" "$OUT/docs/images"

cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$ROOT/THIRD_PARTY.md" "$OUT/"
mkdir -p "$OUT/THIRD_PARTY/linux"
cp "$ROOT"/THIRD_PARTY/*.txt "$OUT/THIRD_PARTY/"
# The Debian copyright files of every system library the package carries (the distribution's licence record).
for lib in "$SDL" "${SYSLIBS[@]+"${SYSLIBS[@]}"}" "$LLVM_SRC/lib/libLLVM.so.22.1" "$LLVM_SRC/bin/clang" "$LLVM_SRC/bin/lld" "$LLVM_SRC/lib/libclang.so" ${DEBUGGER:+"$LLVM_SRC/bin/lldb-dap" "$LLVM_SRC/lib/liblldb-22.so.1"}; do
  [ $DEBUGGER = 0 ] && [[ "$lib" == *lldb* ]] && continue
  real="$(readlink -f "$lib")"
  pkg="$(dpkg -S "$real" 2>/dev/null | head -1 | cut -d: -f1)" || true
  if [ -n "$pkg" ] && [ -f "/usr/share/doc/$pkg/copyright" ]; then
    cp "/usr/share/doc/$pkg/copyright" "$OUT/THIRD_PARTY/linux/$pkg.copyright"
  elif [ -n "$pkg" ]; then
    # Multi-arch packages may keep the copyright under the package name without the arch suffix.
    base="${pkg%%:*}"; [ -f "/usr/share/doc/$base/copyright" ] && cp "/usr/share/doc/$base/copyright" "$OUT/THIRD_PARTY/linux/$base.copyright"
  fi
done
echo "$FULL" > "$OUT/VERSION.txt"

# No build leftovers or test material outside the toolchain.
bad="$(find "$OUT" -path "$OUT/tools" -prune -o -type f \( -name '*.o' -o -name '*.a' -o -name '*.tir' -o -name '*.expected' -o -name '*.build.txt' \) -print)"
[ -z "$bad" ] || die "package contains build or test leftovers: $bad"

# The packaged exe must print the version VERSION.txt says (--version opens no window).
reported="$(timeout 30 "$OUT/treadle" --version 2>/dev/null | head -1 | tr -d '\r')" || true
[[ "$reported" == "Treadle $FULL (host contract "* ]] || die "Treadle --version printed '$reported', expected 'Treadle $FULL (host contract n)'"

# The file list the updater installs by (docs/Releasing.md, "The update path"): every file and link of the package,
# relative; files.txt itself is not listed.
(cd "$OUT" && find . \( -type f -o -type l \) ! -path ./files.txt -printf '%P\n' | LC_ALL=C sort) > "$OUT/files.txt"
# files.sha256: the SHA-256 of every listed file (links excluded, they are copied as links); the update helper copies
# only the files that differ. Not listed, so not installed.
(cd "$OUT" && find . -type f ! -path ./files.txt -printf '%P\n' | LC_ALL=C sort | xargs -d '\n' sha256sum) > "$OUT/files.sha256"

# ------------------------------------------------------------------------------------------- tarball

mkdir -p "$DIST"
DIST="$(cd "$DIST" && pwd)"
TGZ="$DIST/$NAME.tar.gz"
rm -f "$TGZ" "$TGZ.sha256"
tar -C "$(dirname "$OUT")" --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || date +%s)" \
  -cf - "$(basename "$OUT")" | gzip -9n > "$TGZ"
(cd "$DIST" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256")
SHA="$(cut -d' ' -f1 "$TGZ.sha256")"
echo "Packaged $OUT"
echo "  folder $(mb "$OUT") (tools/llvm $(mb "$OUT/tools/llvm"))"
TGZ_BYTES=$(stat -c %s "$TGZ")
echo "  tar.gz $TGZ ($(du -b "$TGZ" | awk '{ printf "%.1f MB", $1 / 1048576 }'); samples $(mb "$OUT/samples") unpacked)"
echo "  samples ${SAMPLES[*]}"
[ "$TGZ_BYTES" -lt $((150 * 1048576)) ] || die "the tarball is over the 150 MB limit (docs/Releasing.md)"
echo "  sha256 $SHA"
echo "  exe    $reported"

[ $VERIFY = 1 ] || exit 0

# ------------------------------------------------------------------------------------------- verify
#
# The tarball is unpacked into the verify folder and the packaged exe runs with TREADLE_LLVM, TREADLE_CORE,
# TREADLE_LIBCLANG, TREADLE_RUNTIME, TREADLE_LLDB_DAP, TREADLE_SAMPLES unset, TREADLE_NO_FALLBACK=1, its own
# TREADLE_HOME and a fresh XDG_CACHE_HOME (no cached runtime object). When unprivileged mount namespaces work
# (unshare -rm), every check also runs with the system's LLVM 22 (/usr/lib/llvm-22, libLLVM, libclang,
# liblldb, libz3, libpython3.14), GCC's files (/usr/lib/gcc) and SDL2 hidden, as on a system without them.

[ -n "$VERIFY_DIR" ] || VERIFY_DIR="${TMPDIR:-/tmp}/treadle-pkg-verify-$(date +%Y%m%d-%H%M%S)"
if [ -d "$VERIFY_DIR" ]; then
  if [ -f "$VERIFY_DIR/verify.marker" ]; then rm -rf "$VERIFY_DIR"
  elif [ -n "$(ls -A "$VERIFY_DIR")" ]; then die "$VERIFY_DIR is not empty and is not an earlier verify folder"; fi
fi
mkdir -p "$VERIFY_DIR"
VERIFY_DIR="$(cd "$VERIFY_DIR" && pwd)"
echo "scripts/package-linux.sh --verify" > "$VERIFY_DIR/verify.marker"
tar -C "$VERIFY_DIR" -xzf "$TGZ"
UNP="$VERIFY_DIR/$NAME"
PEXE="$UNP/treadle"
WORK="$VERIFY_DIR/work"
mkdir -p "$WORK/cimport" "$WORK/cimport-out" "$VERIFY_DIR/cache" "$VERIFY_DIR/home"
cp -r "$ROOT/TreadleCore/samples/m1" "$WORK/m1"
cp -r "$ROOT/TreadleCore/samples/m3-core" "$WORK/m3-core"
cp "$ROOT/tools/probe/headers/small.h" "$WORK/cimport/small.h"
sed 's#\.\./\.\./tools/probe/headers/small\.h#small.h#' "$ROOT/TreadleCImport/fixtures/small.cimport" > "$WORK/cimport/small.cimport"
# The debug self test opens TreadleCore/samples/m1 (TREADLE_SAMPLES points at a copy of the samples folder).
cp -r "$ROOT/TreadleCore/samples" "$WORK/samples"

HIDE=()
for f in /usr/lib/llvm-22 /usr/lib/gcc /usr/lib/x86_64-linux-gnu/libLLVM.so.22.1 /usr/lib/x86_64-linux-gnu/libclang-cpp.so.22.1 \
         /usr/lib/x86_64-linux-gnu/libclang-22.so.22 /usr/lib/x86_64-linux-gnu/liblldb-22.so.1 /usr/lib/x86_64-linux-gnu/libz3.so.4 \
         /usr/lib/x86_64-linux-gnu/libpython3.14.so.1.0 /usr/lib/x86_64-linux-gnu/libipt.so.2 /usr/lib/x86_64-linux-gnu/libSDL2-2.0.so.0; do
  [ -e "$f" ] && HIDE+=("$(readlink -f "$f")")
done
ISOLATE=0
if unshare -rm true 2>/dev/null; then ISOLATE=1; fi
mkdir -p "$VERIFY_DIR/empty"
# Runs the packaged exe with a clean environment (and, when possible, the system toolchain hidden).
run_pkg() { # run_pkg <timeout s> <extra env...> -- <args...>
  local t="$1"; shift
  local -a envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  local -a cmd=(env -u TREADLE_LLVM -u TREADLE_CORE -u TREADLE_LIBCLANG -u TREADLE_RUNTIME -u TREADLE_SAMPLES
    -u TREADLE_LLDB_DAP -u TREADLE_SELFTEST -u TREADLE_UPDATE_INDEX -u LD_LIBRARY_PATH
    TREADLE_NO_FALLBACK=1 TREADLE_HOME="$VERIFY_DIR/home" XDG_CACHE_HOME="$VERIFY_DIR/cache" "${envs[@]+"${envs[@]}"}"
    timeout "$t" nice -n "$NICE" "$RUN_EXE" "$@")
  if [ $ISOLATE = 1 ]; then
    local script="" h
    for h in "${HIDE[@]+"${HIDE[@]}"}"; do
      if [ -d "$h" ]; then script+="mount --bind '$VERIFY_DIR/empty' '$h' && "; else script+="mount --bind /dev/null '$h' && "; fi
    done
    (cd "$RUN_DIR" && unshare -rm sh -c "${script}exec \"\$@\"" sh "${cmd[@]}")
  else
    (cd "$RUN_DIR" && "${cmd[@]}")
  fi
}
RUN_EXE="$PEXE"; RUN_DIR="$UNP"

FAILS=0
OUTF="$VERIFY_DIR/out.txt"
check() { # check <label> <ok 0/1> <ms> <code>
  local tag=ok; [ "$2" = 1 ] || { tag=FAIL; FAILS=$((FAILS + 1)); }
  echo "[$tag] $1  (exit $4, $3 ms)"
  sed 's/^/    /' "$OUTF"
}
now_ms() { local t="${EPOCHREALTIME/[.,]/}"; echo $(( t / 1000 )); }
t0=0; code=0
timed() { t0=$(now_ms); set +e; run_pkg "$@" >"$OUTF" 2>&1; code=$?; set -e; ms=$(( $(now_ms) - t0 )); }

[ $ISOLATE = 1 ] && echo "Verifying with the system's LLVM 22, GCC files and SDL2 hidden (${#HIDE[@]} paths)" \
                 || echo "Verifying without isolation (unshare -rm is not available here)"
timed 30 -- --version
check "--version" $([ $code = 0 ] && grep -q "^Treadle $FULL (host contract" "$OUTF" && echo 1 || echo 0) $ms $code
timed 300 -- --build-run "$WORK/m1"
check "--build-run m1 (fresh: no runtime cache)" $([ $code = 0 ] && echo 1 || echo 0) $ms $code
FRESH_MS=$ms
timed 300 -- --build-run "$WORK/m1"
check "--build-run m1 (again)" $([ $code = 0 ] && echo 1 || echo 0) $ms $code
timed 300 -- --build-run "$WORK/m3-core" -- a b c
check "--build-run m3-core -- a b c" $([ $code = 0 ] && grep -q "3 words, 3 different" "$OUTF" && echo 1 || echo 0) $ms $code
timed 120 -- --import-c "$WORK/cimport/small.cimport" --out "$WORK/cimport-out"
check "--import-c small.cimport" $([ $code = 0 ] && [ -f "$WORK/cimport-out/small.cdecl" ] && echo 1 || echo 0) $ms $code
# The self tests are not in the package (ReleasePackage, no TREADLE_SELFTEST define): no "SELFTEST" in the exe, a
# smaller exe than the Release build of the same source, and TREADLE_SELFTEST set changes nothing (a normal, quiet
# start that runs no self test: still running when timeout ends it after 15 s, no [SELFTEST] line in its log).
# The package strips debug info, so the comparison is with a copy of the Release exe stripped the same way.
TSIZE=0
if [ -f "$TEST_REL/treadle" ]; then
  cp "$TEST_REL/treadle" "$VERIFY_DIR/treadle-release-stripped"
  strip --strip-debug "$VERIFY_DIR/treadle-release-stripped"
  TSIZE=$(stat -c %s "$VERIFY_DIR/treadle-release-stripped")
fi
PSIZE=$(stat -c %s "$PEXE")
NOSTR=1; grep -q -a SELFTEST "$PEXE" && NOSTR=0
echo "packaged $PSIZE bytes, the Release build with the self tests $TSIZE bytes (both without debug info)" > "$OUTF"
check "no SELFTEST string in the packaged exe, smaller than the Release build" $([ $NOSTR = 1 ] && [ "$TSIZE" -gt "$PSIZE" ] && echo 1 || echo 0) 0 0
mkdir -p "$VERIFY_DIR/home-ignored"
timed 15 TREADLE_SELFTEST=smoke,quit TREADLE_WINDOW_HIDDEN=1 TREADLE_HOME="$VERIFY_DIR/home-ignored" --
ILOG="$(ls -t "$VERIFY_DIR"/home-ignored/logs/*.log 2>/dev/null | head -1 || true)"
SLINES=0; STARTED=0
if [ -n "$ILOG" ]; then SLINES=$(grep -c '\[SELFTEST\]' "$ILOG" || true); STARTED=$(grep -c 'Treadle started' "$ILOG" || true); fi
echo "$SLINES self-test lines, started: $STARTED" > "$OUTF"
check "TREADLE_SELFTEST=smoke,quit is ignored by the packaged exe (normal start)" $( { [ $code = 124 ] || [ $code = 2 ]; } && [ "$SLINES" = 0 ] && [ "$STARTED" -ge 1 ] && echo 1 || echo 0) $ms $code
# The Release build (the same source with the self tests) in a copy of the unpacked folder: the debugger self test
# runs on the package's toolchain (tools/llvm/bin/lldb-dap).
TL="$VERIFY_DIR/test-layout"
cp -a "$UNP" "$TL"
cp "$TEST_REL/treadle" "$TL/treadle"
RUN_EXE="$TL/treadle"; RUN_DIR="$TL"
timed 600 TREADLE_SELFTEST=smoke,debug,quit TREADLE_SAMPLES="$WORK/samples" --
RUN_EXE="$PEXE"; RUN_DIR="$UNP"
LOG="$(ls -t "$VERIFY_DIR"/home/logs/*.log 2>/dev/null | head -1 || true)"
DONE=""; DAP=""
if [ -n "$LOG" ]; then
  DONE="$(grep -o '\[SELFTEST\] done failures=[0-9]*' "$LOG" | tail -1 || true)"
  DAP="$(grep -o 'lldb-dap: [^)]*' "$LOG" | tail -1 || true)"
fi
{ echo "$DONE"; echo "$DAP"; } > "$OUTF"
check "TREADLE_SELFTEST=smoke,debug,quit (the Release build in the package layout)" $([ $code = 0 ] && [ "$DONE" = "[SELFTEST] done failures=0" ] && [[ "$DAP" == "lldb-dap: $TL/tools/llvm/bin/"* ]] && echo 1 || echo 0) $ms $code

# Shipped samples, built and run in place in the unpacked folder (their build folders land there). The SDL samples
# link the package's libSDL2-2.0.so.0; with the system's SDL2 hidden they run with LD_LIBRARY_PATH set to the package
# folder (what a system without libsdl2-2.0-0 needs). m2-sdl opens a window, so it runs only where a display is.
PS="$UNP/samples"
timed 300 -- --build-run "$PS/m3-core"
check "--build-run samples/m3-core (shipped, in place)" $([ $code = 0 ] && grep -q "counted in" "$OUTF" && echo 1 || echo 0) $ms $code
timed 300 LD_LIBRARY_PATH="$UNP" -- --build-run "$PS/m4-breakout" -- --headless
check "--build-run samples/m4-breakout -- --headless (the package's libSDL2)" $([ $code = 0 ] && grep -q "frames 600 score" "$OUTF" && echo 1 || echo 0) $ms $code
if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
  timed 300 LD_LIBRARY_PATH="$UNP" -- --build-run "$PS/m2-sdl" -- --frames 60
  check "--build-run samples/m2-sdl -- --frames 60 (the package's libSDL2)" $([ $code = 0 ] && grep -q "frames 60" "$OUTF" && echo 1 || echo 0) $ms $code
else
  echo "[skip] --build-run samples/m2-sdl -- --frames 60: no display (DISPLAY and WAYLAND_DISPLAY are unset)"
fi

# The update rehearsal (docs/Releasing.md, "The update path"): package A is this package with an older VERSION.txt, one
# extra listed file (docs/rehearsal-old-page.md, which B no longer has) and user files the update must keep; a local
# release index (TREADLE_UPDATE_INDEX, the same override every build honours) holds this tarball as release B with its
# SHA256SUMS. A's `treadle --update` checks, downloads, verifies and starts the helper; the helper replaces A's files by
# B's files.txt and restarts with --update-health. Not isolated: the helper outlives the command that started it.
REH="$VERIFY_DIR/update-rehearsal"
RA="$REH/$NAME"
RIDX="$REH/index"
mkdir -p "$RIDX" "$REH/home"
cp -a "$UNP" "$RA"
echo "0.0.1-rehearsal" > "$RA/VERSION.txt"
mkdir -p "$RA/projects/MyGame" "$RA/samples/m1"
echo "user project" > "$RA/projects/MyGame/MyGame.tproj"
echo "user notes inside a package folder" > "$RA/samples/m1/my-notes.txt"
echo "only in A" > "$RA/docs/rehearsal-old-page.md"
echo "docs/rehearsal-old-page.md" >> "$RA/files.txt"
cp "$TGZ" "$RIDX/"
echo "$SHA  $NAME.tar.gz" > "$RIDX/SHA256SUMS"
printf '[{"tag_name": "v%s", "draft": false, "prerelease": false, "body": "Rehearsal release", "assets": [{"name": "%s", "size": %s}, {"name": "SHA256SUMS", "size": 100}]}]' \
  "$FULL" "$NAME.tar.gz" "$TGZ_BYTES" > "$RIDX/releases.json"
reh_run() { (cd "$RA" && env -u TREADLE_SELFTEST -u LD_LIBRARY_PATH TREADLE_HOME="$REH/home" TREADLE_UPDATE_INDEX="$RIDX" XDG_CACHE_HOME="$VERIFY_DIR/cache" timeout "$1" "$RA/treadle" "${@:2}"); }
t0=$(now_ms); set +e; reh_run 600 --update >"$OUTF" 2>&1; code=$?; set -e; ms=$(( $(now_ms) - t0 ))
HPID="$(grep -o 'Update helper started (process [0-9]*' "$OUTF" | grep -o '[0-9]*$' || true)"
check "update rehearsal: 0.0.1-rehearsal --update finds $FULL in the local index, verifies it and starts the helper" $([ $code = 0 ] && [ -n "$HPID" ] && echo 1 || echo 0) $ms $code
ULOG="$RA/update/update.log"
if [ -n "$HPID" ]; then
  for _ in $(seq 1 2400); do kill -0 "$HPID" 2>/dev/null || break; sleep 0.25; done
  kill -0 "$HPID" 2>/dev/null && { kill "$HPID" 2>/dev/null || true; echo "    ! the helper did not finish in 600 s (stopped)"; }
  for _ in $(seq 1 240); do grep -qE "update complete|restoring|update failed|did not close" "$ULOG" 2>/dev/null && break; sleep 0.25; done
fi
VA="$(head -1 "$RA/VERSION.txt" | tr -d '\r')"
KEPT=0; [ -f "$RA/projects/MyGame/MyGame.tproj" ] && [ -f "$RA/samples/m1/my-notes.txt" ] && KEPT=1
GONE=0; [ ! -e "$RA/docs/rehearsal-old-page.md" ] && GONE=1
SAME=0; cmp -s "$RA/files.txt" "$UNP/files.txt" && SAME=1
NOPREV=0; [ ! -e "$RA/update/old" ] && NOPREV=1
EXEC=0; [ -x "$RA/treadle" ] && [ -x "$RA/tools/llvm/bin/clang" ] && [ -L "$RA/tools/llvm/bin/ld.lld" ] && EXEC=1
t0=$(now_ms); set +e; reh_run 30 --version >"$OUTF" 2>&1; code=$?; set -e; ms=$(( $(now_ms) - t0 ))
VLINE="$(head -1 "$OUTF")"
cat "$ULOG" >> "$OUTF" 2>/dev/null || true
check "update rehearsal: VERSION.txt $VA, user files kept $KEPT, A-only file removed $GONE, files.txt is B's $SAME, rollback copy cleared $NOPREV, exec bits and links kept $EXEC" \
  $([ $code = 0 ] && [ "$VA" = "$FULL" ] && [[ "$VLINE" == "Treadle $FULL (host contract "* ]] && [ $KEPT = 1 ] && [ $GONE = 1 ] && [ $SAME = 1 ] && [ $NOPREV = 1 ] && [ $EXEC = 1 ] && grep -q "update complete" "$ULOG" && echo 1 || echo 0) $ms $code
t0=$(now_ms); set +e; reh_run 120 --update >"$OUTF" 2>&1; code=$?; set -e; ms=$(( $(now_ms) - t0 ))
check "update rehearsal: --update again says up to date" $([ $code = 0 ] && grep -q "is up to date" "$OUTF" && echo 1 || echo 0) $ms $code

[ $FAILS = 0 ] || die "verify: $FAILS check(s) failed (work files in $VERIFY_DIR)"
echo "Verified from $UNP with only the package's contents (fresh m1 build $FRESH_MS ms). Work files: $VERIFY_DIR"
