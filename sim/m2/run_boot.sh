#!/bin/sh
# M2 boot run: <bin> <set> <game id> <frames> <out dir> <mame run dir>
# Captures every frame the MAME run has a snapshot for (image of our
# displayed frame N-1, RAM at vblank N).
set -e
bin=$1 set=$2 game=$3 frames=$4 out=$5 mame=$6
rm -rf "$out" && mkdir -p "$out"
ls "$mame/frames" | sed 's/^0*//' | awk '{print $1; print $1-1}' | sort -n | uniq | awk '$1>0' > "$out/cap.txt"
"$bin" +game="$game" +sdram="build/regions/$set/sdram.bin" +frames="$frames" \
  +cap="$out/cap.txt" +out="$out" > "$out/run.log"
