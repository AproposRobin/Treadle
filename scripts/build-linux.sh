#!/bin/bash
# Builds Treadle on Linux and runs the self tests (docs/Linux-Development.md):
#   1. the native host, Native/bin/linux64/libtreadlehost.so (Native/build_linux.sh, incremental), when needed (below)
#   2. TreadleEditor with BeefBuild, for each configuration
#   3. the self tests (TREADLE_SELFTEST) of each build, in a scratch TREADLE_HOME
#
# Usage: scripts/build-linux.sh [Debug|Release|both|ReleasePackage] [self-test list|none]
#   default: both, smoke,codec,editor,backend,frontend,cimport,core,debug,quit
# Environment: BEEFBUILD (else BeefBuild on PATH, else ~/beef/IDE/dist/BeefBuild), TREADLE_LLVM
# (else /usr/lib/llvm-22), TREADLE_BUILD_HOST=1 (rebuild the native host), NICE (default 10). The editor windows of the self tests need a display
# (WSLg, X11 or Wayland). Exit code: 0 when every build succeeded and every self test passed.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHICH="${1:-both}"
TESTS="${2:-smoke,codec,editor,backend,frontend,cimport,core,debug,quit}"
: "${NICE:=10}"
BB="${BEEFBUILD:-}"
if [ -z "$BB" ]; then
  if command -v BeefBuild >/dev/null; then BB="$(command -v BeefBuild)"
  elif [ -x "$HOME/beef/IDE/dist/BeefBuild" ]; then BB="$HOME/beef/IDE/dist/BeefBuild"
  else echo "BeefBuild not found: put it on PATH or set BEEFBUILD (docs/Linux-Development.md)"; exit 2; fi
fi
case "$WHICH" in
  both) CONFIGS="Debug Release" ;;
  ReleasePackage) CONFIGS="ReleasePackage" ;; # the package build: no self tests (TESTS is ignored)
  Debug|Release) CONFIGS="$WHICH" ;;
  *) echo "usage: $0 [Debug|Release|both|ReleasePackage] [self-test list|none]"; exit 2 ;;
esac

# The host binary is committed; rebuilding it rewrites a tracked file (same exports; the same bytes from the same toolchain, packaging/host-sha256.txt). It is
# built when asked (TREADLE_BUILD_HOST=1), when it is missing or does not load on this system (ldd names a
# library or symbol version it cannot find: the committed one needs glibc 2.43), or when this checkout has
# built it before (Native/obj/linux64 exists: the build is incremental, so host source changes are picked up).
SO="$ROOT/Native/bin/linux64/libtreadlehost.so"
if [ "${TREADLE_BUILD_HOST:-0}" = "1" ] || [ ! -f "$SO" ] || [ -d "$ROOT/Native/obj/linux64" ] \
   || ldd "$SO" 2>&1 | grep -q "not found"; then
  echo "== native host"
  NICE=$NICE bash "$ROOT/Native/build_linux.sh" || exit 1
else
  echo "== native host: the committed Native/bin/linux64/libtreadlehost.so loads here (TREADLE_BUILD_HOST=1 rebuilds it)"
fi

status=0
for cfg in $CONFIGS; do
  echo "== TreadleEditor $cfg"
  log="$(mktemp -t treadle-build-XXXXXX.log)"
  if ! nice -n "$NICE" "$BB" -workspace="$ROOT" -config="$cfg" >"$log" 2>&1; then
    grep -E "ERROR|error:" "$log" | head -40
    echo "BeefBuild $cfg failed (log: $log)"
    status=1
    continue
  fi
  tail -3 "$log"
  rm -f "$log"
  [ "$TESTS" = "none" ] && continue
  [ "$cfg" = "ReleasePackage" ] && continue # no self tests in the package build

  echo "== self tests $cfg: $TESTS"
  home="$(mktemp -d -t treadle-selftest-XXXXXX)"
  start=$(date +%s)
  TREADLE_HOME="$home" TREADLE_SELFTEST="$TESTS" timeout 1800 \
    "$ROOT/build/${cfg}_Linux64/TreadleEditor/treadle" >"$home/stdout.txt" 2>&1
  code=$?
  sessionlog="$(ls "$home"/logs/*.log 2>/dev/null | head -1)"
  ok=0; done_line=""
  if [ -n "$sessionlog" ]; then
    ok=$(grep -c "\[SELFTEST\] ok" "$sessionlog")
    grep "\[SELFTEST\] FAIL" "$sessionlog"
    done_line=$(grep -o "\[SELFTEST\] done failures=[0-9]*" "$sessionlog" | tail -1)
  fi
  echo "$cfg: exit $code, $ok checks passed, ${done_line:-no done line} ($(( $(date +%s) - start )) s)"
  if [ "$code" -ne 0 ] || [ "$done_line" != "[SELFTEST] done failures=0" ]; then
    echo "session log and stdout kept in $home"
    status=1
  else
    rm -rf "$home"
  fi
done
exit $status
