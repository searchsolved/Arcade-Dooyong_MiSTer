#!/bin/sh
# Headless MAME wrapper used by every oracle target.
#   sim/mame/run_mame.sh <set> <lua script> [extra mame args...]
# Environment for the Lua script is passed through (DUMP_DIR, DUMP_FRAMES...).
# MAME runtime dirs (cfg, nvram, snap) go under sim/mame/out/runtime so runs
# never read a stale cfg/nvram from a previous session: the directory is
# wiped per run, which keeps every oracle run reproducible from power-on.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
MAME=${MAME:-mame}
SET=$1; shift
SCRIPT=$1; shift
RT="$HERE/out/runtime/$SET"
# snapshot paths in the Lua scripts are resolved against the snapshot dir, so
# hand the scripts an absolute DUMP_DIR
if [ -n "$DUMP_DIR" ]; then mkdir -p "$DUMP_DIR"; DUMP_DIR=$(cd "$DUMP_DIR" && pwd); export DUMP_DIR; fi
rm -rf "$RT"; mkdir -p "$RT"
export SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy
exec "$MAME" "$SET" -rompath "$ROOT/roms" -video none -sound none -nothrottle \
  -skip_gameinfo -nonvram_save \
  -cfg_directory "$RT/cfg" -nvram_directory "$RT/nvram" \
  -snapshot_directory "$RT/snap" -diff_directory "$RT/diff" \
  -input_directory "$RT/inp" -state_directory "$RT/sta" \
  -autoboot_script "$SCRIPT" "$@"
