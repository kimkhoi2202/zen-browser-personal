#!/bin/bash
# Builds the personal Zen engine from source, natively on Apple Silicon, the
# way Zen builds its official macOS releases: configs/common and configs/macos
# with ZEN_RELEASE (optimize, release, Rust SIMD, MOZILLA_OFFICIAL,
# cross-language ThinLTO, -mcpu=apple-m1, the 26.5 SDK) plus a local two-stage
# PGO run with Zen's profile-server training. The updater is not built:
# personal channels never self-update.
#
# Needed when a personal change includes native code (such as the Yab-style
# PiP chrome), which the released-engine artifact builder cannot carry. The
# packaged result is the --base for `build_macos.py --source-built`.
#
#   scripts/personal/build_engine.sh prepare        import patches, en-US strings
#   scripts/personal/build_engine.sh instrumented   PGO stage 1 build + package
#   scripts/personal/build_engine.sh profile        PGO training run (opens a window)
#   scripts/personal/build_engine.sh optimized      PGO stage 2 build with LTO
#   scripts/personal/build_engine.sh package        package the optimized engine
#   scripts/personal/build_engine.sh all
#
# Run from a committed checkout whose engine/ holds the pinned Firefox source
# (see personal/Native Engine Builds.md). Keep it outside iCloud-synced
# folders; it needs about 45 GB. Environment: MOZBUILD_STATE_PATH (toolchains),
# ZEN_BUILD_JOBS (default 12), ZEN_PGO_DIR (default ../pgo), ZEN_LOG_DIR
# (default ../logs), ZEN_PYTHON (default python3.12; mach does not support
# newer Pythons).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ENGINE="$ROOT/engine"
PGO_DIR="${ZEN_PGO_DIR:-$ROOT/../pgo}"
LOG_DIR="${ZEN_LOG_DIR:-$ROOT/../logs}"
JOBS="${ZEN_BUILD_JOBS:-12}"
STATE="${MOZBUILD_STATE_PATH:-$HOME/.mozbuild}"
PYTHON="${ZEN_PYTHON:-python3.12}"
INSTRUMENTED_OBJDIR=obj-pgo-instrumented
OPTIMIZED_OBJDIR=obj-aarch64-apple-darwin
FORK_URL=https://github.com/kimkhoi2202/zen-browser-personal

mkdir -p "$PGO_DIR" "$LOG_DIR"
cd "$ROOT"

if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo "This builds the arm64 macOS engine natively; run it on Apple Silicon." >&2
  exit 1
fi
if [ ! -f "$ENGINE/toolkit/moz.build" ] || [ ! -d "$ENGINE/.git" ]; then
  echo "engine/ is not an initialized Firefox source tree (npm run download)." >&2
  exit 1
fi

# Zen's release options come from its own configs; PGO flags come from here so
# the profile lives in ZEN_PGO_DIR instead of Zen CI's ~/artifact.
export ZEN_RELEASE=1 ZEN_GA_DISABLE_PGO=1 SURFER_PLATFORM=darwin

write_mozconfig() {
  local stage=$1
  {
    echo "# Written by scripts/personal/build_engine.sh ($stage stage); local only."
    echo "# surfer merges it after configs/common and configs/macos."
    echo "ac_add_options --disable-updater"
    echo "mk_add_options MOZ_PARALLEL_BUILD=$JOBS"
    echo "export MOZ_SOURCE_REPO=$FORK_URL"
    if [ "$stage" = instrumented ]; then
      echo "mk_add_options MOZ_OBJDIR=@TOPSRCDIR@/$INSTRUMENTED_OBJDIR"
      echo "ac_add_options --enable-profile-generate=cross"
    else
      echo "ac_add_options --enable-profile-use=cross"
      echo "ac_add_options --with-pgo-profile-path=$PGO_DIR/merged.profdata"
      echo "ac_add_options --with-pgo-jarlog=$PGO_DIR/en-US.log"
    fi
  } > "$ROOT/mozconfig"
  # The instrumented build only collects counters; LTO there costs time only.
  if [ "$stage" = instrumented ]; then export ZEN_DISABLE_LTO=1; else unset ZEN_DISABLE_LTO; fi
  SURFER_MOZCONFIG_ONLY=1 npx surfer build > "$LOG_DIR/mozconfig-$stage.log" 2>&1
}

mach() {
  (cd "$ENGINE" && nice -n 10 "$PYTHON" ./mach --no-interactive "$@")
}

stage_prepare() {
  if [ -n "$(git status --porcelain)" ]; then
    echo "Commit or stash source changes first; the engine records HEAD." >&2
    exit 1
  fi
  echo "importing patches ($(git rev-parse --short HEAD))"
  npm run import > "$LOG_DIR/import.log" 2>&1
  "$PYTHON" scripts/copy_language_pack.py en-US > "$LOG_DIR/language-pack.log" 2>&1
}

stage_instrumented() {
  write_mozconfig instrumented
  echo "PGO stage 1: instrumented build"
  mach build > "$LOG_DIR/build-instrumented.log" 2>&1
  mach package > "$LOG_DIR/package-instrumented.log" 2>&1
}

stage_profile() {
  write_mozconfig instrumented
  local app="$ENGINE/$INSTRUMENTED_OBJDIR/dist/zen/Zen.app"
  [ -x "$app/Contents/MacOS/zen" ] || { echo "no instrumented app at $app" >&2; exit 1; }
  if [ ! -d "$ENGINE/pgo-extended-corpus" ]; then
    mach python ../scripts/download_pgo_extended_corpus.py > "$LOG_DIR/pgo-corpus.log" 2>&1
  fi
  echo "PGO training run (an instrumented Zen window opens for several minutes)"
  rm -f "$ENGINE/merged.profdata" "$ENGINE/en-US.log"
  (cd "$ENGINE" && LLVM_PROFDATA="$STATE/clang/bin/llvm-profdata" JARLOG_FILE=en-US.log \
    "$PYTHON" ./mach --no-interactive python build/pgo/profileserver.py \
      --binary "$app/Contents/MacOS/zen" --extended-corpus ./pgo-extended-corpus) \
    > "$LOG_DIR/pgo-profile.log" 2>&1
  mv "$ENGINE/merged.profdata" "$ENGINE/en-US.log" "$PGO_DIR/"
  ls -la "$PGO_DIR"
}

stage_optimized() {
  [ -s "$PGO_DIR/merged.profdata" ] && [ -s "$PGO_DIR/en-US.log" ] ||
    { echo "run the profile stage first" >&2; exit 1; }
  write_mozconfig optimized
  echo "PGO stage 2: optimized build with LTO"
  mach build > "$LOG_DIR/build-optimized.log" 2>&1
}

stage_package() {
  write_mozconfig optimized
  mach package > "$LOG_DIR/package-optimized.log" 2>&1
  local app="$ENGINE/$OPTIMIZED_OBJDIR/dist/zen/Zen.app"
  local stamp
  stamp=$(sed -n 's/^SourceStamp=//p' "$app/Contents/Resources/application.ini")
  echo "engine: $app"
  echo "source: $stamp ($(lipo -archs "$app/Contents/MacOS/zen"))"
}

case "${1:-}" in
  prepare|instrumented|profile|optimized|package) "stage_$1" ;;
  all) stage_prepare; stage_instrumented; stage_profile; stage_optimized; stage_package ;;
  *) sed -n '2,24p' "$0" >&2; exit 2 ;;
esac
