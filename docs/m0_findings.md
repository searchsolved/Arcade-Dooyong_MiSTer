# M0 findings: ROM validation and MAME oracle bootstrap

Date: 2026-09-27. Oracle: MAME 0.288 (Homebrew build, `mame -version`
reports `0.288 (unknown)`), ROMs: MAME 0.289 merged set in `roms/`.
Everything below is reproducible with `cd sim && make m0` (about 5 minutes
of wall time; outputs in `sim/build` and `sim/mame/out`, both gitignored,
about 3 GB with the default capture plan).

## 1. Gate

PLAN M0 gate and result:

| Gate item | Result | Evidence |
|---|---|---|
| All 25 sets pass CRC (except the known BAD_DUMP) | PASS | `make roms-check`: 25/25 complete; CRC32, SHA1 and size of every file checked against the table generated from `reference/mame/dooyong.cpp`; the only note is the expected polluxn `polluxntc_4.8r` BAD_DUMP |
| SDRAM images built | PASS | `make regions`: every region of all 25 sets rebuilt from the ROM_START blocks; region sizes and totals equal spec 13 for all ten parents; `sdram.bin` per set in the PLAN 4.3 layout |
| Region images equal MAME's own view | PASS | `make mame-regions`: all regions of all 25 sets dumped from MAME and compared byte for byte, 25/25 MATCH |
| Python renderer matches MAME on every captured frame of flytiger and bluehawk | PASS | `make oracle-verify`: 3,875/3,875 frames pixel-exact (details in 3) |
| Spec updated with O1/O9/O10 | PASS | spec 7.2 (O1), 7.3 (O9), 5.4 (O10), 11.10 (flip closed form), 6.3 (power-on pens), 14 |

MAME 0.288 vs 0.289 ROMs: `mame -verifyroms` in 0.288 reports all 25 sets
OK, and the region dumps above were taken from 0.288 running those zips. No
mismatch. The spec was written from the MAME master driver (2026-09-27); the
renderer, built from that spec, matches 0.288 on every frame, so no
behavioural difference between the two driver versions showed up in the
features exercised.

## 2. Files

| Path | Purpose |
|---|---|
| `tools/romdefs.py` | ROM_START parser and region builder (LOAD, LOAD16_BYTE, LOAD16_WORD_SWAP, CONTINUE, RELOAD, FILL); the expected-ROM table is generated from the vendored driver |
| `tools/check_roms.py` | M0.1 ROM check (CRC over the merged zip, so renamed clone files still match) |
| `tools/build_regions.py` | M0.2 region images (`.bin`, `$readmemh` `.hex`), `sdram.bin`, `manifest.json` per set under `sim/build/regions/<set>/` |
| `tools/compare_regions.py` | builder vs MAME region dumps |
| `tools/analyze_maps.py` | O1 map ROM analysis |
| `tools/analyze_writes.py` | O9/O10/T2/T4 summaries of an oracle write log |
| `tools/oracle_coverage.py` | which renderer features a capture exercised |
| `sim/Makefile` | all M0 targets |
| `sim/mame/run_mame.sh` | headless MAME wrapper (fresh cfg/nvram per run) |
| `sim/mame/dump_regions.lua` | region dump |
| `sim/mame/dy_oracle.lua` | write taps with beam position, per-frame state dumps and frame capture, inputs/DIP control; all ten parents |
| `sim/mame/frame_tools.py` | frame image helpers |
| `sim/oracle/dy_render.py` | reference renderer, Z80 family (spec 6-12) |
| `sim/oracle/compare_frames.py` | renderer vs MAME, per frame |

Byte order convention for every `.bin` in the project: 8-bit data as is;
16-bit regions and RAMs high byte first (the logical big-endian view MAME's
gfx decoder and `required_region_ptr<u16>` use). The `.hex` files of 16-bit
regions hold one 4-digit word per line. Palette RAM dumps of the Z80 games
are raw CPU bytes (little-endian words, spec 6).

SDRAM layout (PLAN 4.3, now fixed in `build_regions.py`): main 0x000000,
sound 0x040000, text 0x050000, OKI 0x080000 (256 KB; flytiger's 512 KB
region is cut to 256 KB after checking the cut part is zero), aux 0x0C0000
(tmap_hi, or bg0_tmap at +0 and fg0_tmap at +0x20000), sprites 0x140000,
bg0 0x340000, bg1 0x440000, fg0 0x540000, fg1 0x640000, end 0x740000.
gundl94's cpu2/gfx4 are not placed.

## 3. Oracle captures and renderer parity

Captures (`make oracle`, about 70 s):

| Run | Frames dumped | Content |
|---|---|---|
| flytiger_attract | 1,625: every 8th frame of 1-8800 (two attract loops) plus 600 consecutive frames 2000-2599 (demo play) | boot, intro, boss intro, title, demo play, high-score entry |
| flytiger_flip | 300 (every 10th of 1-3000), DSWA Flip Screen on | same, flipped |
| bluehawk_attract | 1,650: every 8th of 1-9000 plus 600 consecutive frames 600-1199 | title, ranking, several demo stages |
| bluehawk_flip | 300, flipped | |

Per dumped frame: `snap.png` (MAME snapshot), `screen.argb` plus
`palette_next.bin` (see 6.1), `palette.bin`, `palette_written.bin`,
`pens.bin` (MAME's resolved pen colours), `text.bin`, `spriteram_live.bin`,
`spriteram_buf.bin` (the vblank copy that is drawn), `state.json` (all
tilemap registers of every layer, palette bank, flytiger priority bit, flip,
ROM bank, last control write). Per run: `writes.csv` (every tilemap
register, control, bank, sound latch, ROM-area, unknown-I/O, YM and OKI
write with frame, line and pixel position), `heavy_summary.csv` (palette,
text and sprite RAM writes per frame, with visible-area counts),
`frames.csv` (register state every frame), `inputs.csv`, `summary.txt`
(tap hit counts; every tap was live).

Result (`make oracle-verify`, about 50 s):

| Run | Snapshot check | pixels() check |
|---|---|---|
| flytiger_attract | 1,625/1,625 exact | 1,624 exact, 1 skipped |
| flytiger_flip | 300/300 | 299, 1 skipped |
| bluehawk_attract | 1,650/1,650 | 1,647, 3 skipped |
| bluehawk_flip | 300/300 | 297, 3 skipped |

That is 357 million snapshot pixels compared with zero differences. The skipped
secondary checks are the 1 + 3 boot frames that show never-written palette
entries (6.2). Feature coverage of the matched frames (`tools/oracle_coverage.py`):
format A layers (flytiger bg0/fg0, bluehawk fg1, the latter visibly drawn
in about half the frames), format B (bluehawk bg0/fg0), layer disable,
non-zero Y scroll, flytiger bg0/fg0 priority swap (806 frames), palette
bank, sprite code bit 11, multi-tile height, both Y-shift extensions,
sprite X and Y flip (bluehawk only; flytiger never sets them), colour 0/15
sprites (the 0xFC priority mask), screen flip for all layers and sprites.
Not exercised: flytiger palette bank 0 with content on screen, bluehawk
layer disable. These go into M1's synthetic scenes.

Beyond the gate, `make oracle-extra` runs 300 sampled frames of each other
Z80 parent: lastday, gulfstrm, pollux, sadari and gundl94 are all 300/300
pixel-exact, which covers the separate map ROMs, xBGR_444, the text Y
offset, pollux's palette bank and the primella composition.

## 4. O10: mid-frame register writes

Beam position of each write comes from `screen:time_until_pos(0, 0)`
inside the tap (checked: the frame notifier sits exactly at line 248,
pixel 0). Survey: 12,000 attract frames of each of the ten parents
(`make survey`). Full table in spec 5.4. Summary:

- bluehawk writes all video registers in vblank. flytiger and gulfstrm
  let a few scroll updates run into lines 8-31.
- pollux changes scroll registers anywhere on screen (about a third of its
  scroll changes) and toggles ctrl bit 2 about 11 times per frame, 8 of
  them during the visible area.
- superx, rshark and popbingo do all scroll updates in the line-120 IRQ6
  handler; the writes land at lines 120-135 every frame.
- MAME shows none of this because it draws the frame at line 248 from the
  final values. For MAME parity the RTL must latch the tilemap registers
  (and flytiger's priority bit) at vblank. New research item R12: do the
  real boards latch too? A 68000-game recording would show a tear near line
  123 if they do not.

Palette writes inside the visible area: flytiger and bluehawk 3 frames each
(frames 1-67 of boot), pollux 62 of 856 frames with palette writes, primella family every
palette frame (their whole 256-line frame is visible). Text RAM is written
during the visible area in most frames on every Z80 game; it is not
buffered in MAME either, so the same latch-or-not question applies to text
and palette. Sprite RAM writes during the visible area are harmless (the
buffer is copied at vblank).

## 5. O1, O9, T2, T4, T18

- O1 (spec 7.2): the map ROM data beyond word 0x4000 on lastday, gulfstrm
  and pollux bg0 is 0xFFFF fill; on pollux fg0 it is an older build of the
  pollux main program, identical in both byte lanes, i.e. reused EPROMs. The
  polluxn BAD_DUMP bytes all sit in that unused part. Register 2 is a
  per-game constant (0x00 or 0xFF) in all ten games and the largest reg1
  values keep every map access below word 0x3D00. MAME's model needs no
  extension.
- O9 (spec 7.3): lastday, gulfstrm, pollux, flytiger use format A on both
  layers; bluehawk bg0/fg0 format B but **fg1 format A**; primella family
  and the 68000 games format B.
- T2 (spec 3.8): flytiger's ROM-area writes are `00` then the ROM's own
  first 31 bytes shifted by one, then two field stores: the Z80 block-fill
  idiom run on a zero pointer. Software, not hardware.
- T4: every YM2151 game's sound program writes 0x0003=0x00 and
  0x0004=0xF7 about three times per frame.
- T3: rshark, superx, popbingo write 0x0000 to +0x18 and +0x1A once per
  frame (watchdog-like cadence; MAME ignores them and the games run).
- T18: gundl94 cpu2 begins with the same Z80 reset stub as flytiger and
  bluehawk and shares a few short runs with the flytiger main ROM; gfx4
  matches nothing in the ten sets. Left unidentified.
- O9 by-product: registers 5 and 7 are written once at boot and never
  change.

## 6. Surprises (tooling and model)

### 6.1 screen:pixels() is one frame late

In MAME 0.288 `screen:pixels()` called from the frame notifier returns the
previous frame. `screen_device::update_quads()` flips `m_curbitmap` right
after rendering, and `pixels()` reads `m_bitmap[m_curbitmap]`. Found when
flytiger frame 840 matched the fg0 X scroll of frame 839 exactly (and no
other value). It also converts pens with the palette current at the call,
not at render time, which showed up as whole-screen colour errors on fade
frames. The oracle therefore uses the snapshot (`screen:snapshot`, through
the render texture, current frame) as the primary capture and keeps
`pixels()` from the next notifier, plus the palette at that moment, as an
independent second check. Hyper Duel's taps used snapshots, which is why it
never met this.

### 6.2 MAME power-on pens

MAME starts every pen at a default pattern (0 black, 1 red, 15 white, ...)
and only follows palette RAM after the first write to that entry. The first
few boot frames of flytiger and bluehawk show such pens (white or
cyan/magenta screens). The oracle now tracks which entries have been
written and dumps MAME's pen colours; the comparison checks that every
written entry decodes from RAM to exactly MAME's pen, on every frame, and
uses MAME's pen for unwritten ones. The core should not copy the pattern
(real SRAM is undefined at power-on).

### 6.3 Flip formula

Spec 11.10 quoted MAME's `screen_width - tilemap_width - (dx_flipped -
scroll)` correctly, but applying it as a forward offset failed on every
flipped frame. The working closed form is `tx = (scroll + 511 - x) mod W`
(and `255 - y` vertically), now in spec 11.10.

### 6.4 Lua API gaps in MAME 0.288

- `screen:vpos()` / `hpos()` do not exist (nil methods), confirming the
  Hyper Duel note; `screen:time_until_pos()` and `frame_number()` work
  inside taps.
- `screen:snapshot(path)` resolves relative paths against the snapshot
  directory, so the wrapper passes an absolute `DUMP_DIR`.
- 68000 write taps must start on an even address; byte registers at odd
  addresses are tapped as the whole word.
- The primella configuration's visible area is all 256 lines, so its
  vblank (and the frame notifier) is at line 0, not 248.

## 7. What M1 (video RTL) needs next

1. Register latch at vblank: latch all eight registers of every ROM layer,
   the control bits that affect video (flip, palette bank, flytiger
   priority, lastday sprite disable, primella text priority) at the start
   of line 248 and render the frame from the latched copy. Palette and text
   RAM are read live by MAME at line 248, so a scanline renderer reading
   them during scan-out can differ from MAME on frames with visible-area
   writes (pollux, primella family). The Verilator parity harness should
   replay the dumps as frame-level state (which is what the renderer does);
   a separate line-accurate mode can come later with R12 evidence.
2. Replay inputs are ready: per frame, `state.json` (registers),
   `palette.bin`, `text.bin`, `spriteram_buf.bin`, region `.hex` files
   under `sim/build/regions/<set>/`. A small converter from a frame
   directory to `$readmemh` files (Hyper Duel's `dump_to_hex.py` pattern)
   is the first M1 tool.
3. The renderer is the model: port its per-layer rules directly
   (`rom_layer_pixmap`, `scroll_sample` including the flipped form,
   `draw_z80_sprites` with the first-drawn-wins priority mask, the
   composition order per game).
4. Synthetic scenes for features the attract captures did not exercise:
   flytiger sprite flips, bluehawk layer disable, palette bank 0 on
   flytiger, sprite X at 0x1F0-0x1FF (the 9-bit X wrap is not special-cased
   by MAME; sprites simply clip), Y-shift negative positions.
5. Tilemap map address: 15 bits suffice for all games, but keep the
   `& (length - 1)` mask semantics per game for the 0x40BF edge.
6. 68000 family renderer (16x16 layers, colour ROM, 68000 sprite list) is
   not in `dy_render.py` yet; it is needed before Super-X/R-Shark enter M1.
   The oracle Lua already handles those games (survey runs work).
