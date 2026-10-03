# Dooyong MiSTer Core - Plan

Written 2026-09-27. Companion to `docs/dooyong_system_spec.md` (the
spec); section numbers like "spec 7.2" and IDs like T7 / O1 refer to it.
Method copied from Hyper Duel (`../hyperduel-mister`): MAME is the
behavioural oracle, every RTL block is proven pixel- or word-exact
against it in Verilator before integration, the full system boots in
simulation before Quartus, and hardware testing comes last. Where the
real board is suspected to differ from MAME, the difference is logged as
a research item and resolved only with evidence (recordings, PCB photos,
measurements), as in Hyper Duel's `docs/ACCURACY.md`.

Status 2026-09-28: M0 complete, gate PASS (`docs/m0_findings.md`). M1 and M2
gates PASS for flytiger and bluehawk (`docs/m1_findings.md`, `docs/m2_findings.md`).
ROMs (MAME 0.289 merged set) are in `roms/`; the oracle is MAME 0.288.

Decision 2026-09-29 (Lee): all hardware QA (Blue Hawk on hardware, DIPs,
long play, R13 by ear) is deferred until every game is in the core, then
done once as M5. Flying Tiger passed its first hardware test on 09-29.

Status 2026-09-30: all ten parents (25 sets) in the core and on the MiSTer
(Dooyong_20260930.rbf): Z80 family (docs/primella_findings.md,
docs/ym2203_findings.md) and the 68000 family on fx68k
(docs/m68k_findings.md). Open research: R12 (register latching), R13/R15/
R16 (interrupt and timer timing against MAME), R14 (primella display).
Next: M5 hardware QA of every game.

Status 2026-09-29: primella family (sadari, gundl94, primella) through M1,
M2, M3 and the board sim (`docs/primella_findings.md`); not yet built or
run on hardware.

## 1. Scope

Ten parent games, 25 MAME sets (spec 1). Two CPU families:

- Z80 family (7 parents): lastday, gulfstrm, pollux (2x YM2203);
  flytiger, bluehawk, sadari, gundl94 (YM2151 + M6295).
- 68000 family (3 parents): superx, rshark, popbingo (YM2151 + M6295).

All share: a Z80 sound CPU, the ROM tilemap scheme (spec 7), a 16-colour
x 16-pen palette organisation (spec 6), buffered sprite RAM copied at
vblank (spec 10) and a 512 x 256 MAME screen with a 384-wide visible
area (spec 5.3).

## 2. Reuse inventory

| Block | Source | Status |
|---|---|---|
| fx68k | vendored in `hyperduel-mister/rtl/vendor/fx68k` (with the `ifdef VERILATOR` struct patch, see its `PATCHES.md`) | proven on MiSTer in Hyper Duel |
| jt51 (YM2151) | vendored in Hyper Duel | proven |
| jt6295 (M6295) | vendored in Hyper Duel (`ramstyle=logic` patch) | proven |
| jt03 (YM2203) | jotego `jt12` repository (`jt03` top level, includes SSG) | not yet fetched |
| T80 (Z80) | not in Hyper Duel. Take `T80` / `T80s` from a MiSTer-devel arcade core or jotego `jtframe` (`hdl/cpu/t80`, wrapped by `jtframe_z80`). Record the exact source commit in `CREDITS.md` | not yet fetched |
| MiSTer framework `sys/` | Template_MiSTer, as used by Hyper Duel | proven |
| RAM wrappers | `hyperduel-mister/rtl/hd_dpram.sv`, `hd_tdpram.sv` (explicit altsyncram in synthesis, plain arrays under Verilator) | proven; use from day one to avoid the Quartus inference balloon Hyper Duel hit (`plan_synthesis_and_bringup.md` section 2) |
| SDRAM controller + ioctl download path | `hyperduel-mister/rtl/hyprduel_sdram.sv` | proven; region layout changes |
| Sim harness pattern | `hyperduel-mister/sim` (Makefile targets, PPM diff tools, Lua taps) | copy and adapt |

Fetching T80 and jt03 is a public-source download; do it once, at a
fixed commit, when M2/M3 start.

## 3. Recommended variant order

1. **Flying Tiger (flytiger).** Reasons from the driver:
   - Best documented Z80 board: the driver carries a PCB layout with
     measured clocks for every chip (Z80H 8 MHz, Z80B 4 MHz, YM2151
     3.579545 MHz, M6295 1 MHz /132, HSync 15.68 kHz, VSync 60 Hz;
     spec 2 and 2327-2394). Lastday also has verified clocks, but uses
     the YM2203 pair with the IRQ workaround (T7).
   - YM2151 + M6295 sound on proven cores (jt51, jt6295). Avoids T7/T8
     on the first target.
   - Exercises most of the Z80 video features at once: map format A in
     combined tile+map ROMs, palette banking with the 2048-entry
     palette, the bg0/fg0 priority swap, text in the lane-split layout,
     and three of the four sprite extensions (12-bit code, height/flip,
     Y shift).
   - Only two ROM layers.
2. **Blue Hawk (bluehawk).** Same sound path and CPU pair. Adds the
   third ROM layer (fg1, drawn above sprites), map format B, the
   byte-interleaved text layout with packed 8x8 chars, and the bluehawk
   Y-shift. Its clocks are all unverified (T20), which is why it comes
   second, not first.
3. **Sadari, Gun Dealer '94, Primella.** Same core with sprites removed
   and the text-priority bit (spec 11.6). ROT0. Low effort once 1-2
   work.
4. **Pollux, Gulf Storm, The Last Day.** Brings in 2x jt03 and the IRQ
   question (T7), the 8 MHz sound CPU hack (T8), the separate map ROMs
   (O1), lastday's xBGR_444 palette, text Y offset and sprite disable.
   Pollux first (clocks marked verified, reference video cited at
   line 63), then gulfstrm, then lastday.
5. **Super-X, R-Shark.** Adds fx68k, the 68000 bus, four 16x16 ROM
   layers with the colour ROM (spec 7.4), 68000 sprites (spec 10.2) and
   the scanline IRQs (spec 5.2). Largest ROM sets (7 MB).
6. **Pop Bingo.** Reuses 5, plus the 8-bit composite background mixing
   (spec 11.9) and its unknown registers (T6).

The driver gives no reason to reorder. The one argument for starting
with R-Shark instead would be fewer unknowns in its sprite format (an
explicit enable bit, no extension flags), but that is outweighed by
the 68000 bus work and the larger ROMs.

## 4. Shared-RTL strategy

### 4.1 Recommendation

One source tree, one core (`Arcade-Dooyong`), game selected at load
time by a game ID in the MRA. Target a single RBF containing both CPU
families. Keep compile-time defines (`DY_NO_68K`, `DY_NO_YM2203`) so the
build can be split into two RBFs (Z80 family, 68000 family) if the M4
fit report shows a resource or timing problem.

Reasons:
- The games differ in address decode, a handful of flags and ROM layout,
  not in structure. Every difference in spec sections 3-11 is a small
  mux or a parameter: map offsets, tile size, map format, colour source,
  sprite extension flags, text byte layout, palette format and bank bit,
  layer priorities.
- MiSTer users get one core and 25 MRAs.
- Fewer Quartus builds. The compile PC has been unstable under sustained
  load (memory note `compile_pc_instability.md`: random access
  violations and WHEA errors in August 2026), so each avoided build
  saves real time.

Per-game parameters carried by the game ID (decoded in RTL, not loaded
as raw values, so a bad MRA cannot create an illegal configuration):
CPU family; sound config; main and sound memory map; per-layer
{present, tile size, rows, map base/length, colour source, transparent
pen, colour base}; text layout and char format; sprite format and
extension flags; palette format, size and bank bit; ctrl register bit
map; input port order; visible-area height.

### 4.2 FPGA resource estimate (DE10-Nano, Cyclone V 5CSEBA6U23I7)

Device: 41,910 ALMs, 553 M10K blocks (figures as used in Hyper Duel's
fit reports and plans).

Anchor: Hyper Duel's first fitting build used 38% of ALMs and 98% of
M10K (`handoff_blank_screen_investigation.md` line 7) with 2x fx68k,
jt51, jt6295, the full I4220 video chip (three 64K x 16 VRAMs, blitter,
zoomed sprites) and the MiSTer framework. Its three VRAMs alone took
about 307 M10K (`plan_synthesis_and_bringup.md` section 1).

Dooyong unified build versus that anchor:
- CPUs: one fx68k instead of two, plus two T80s (main and sound).
- Sound: jt51 + jt6295 as before, plus two jt03.
- Video: a scanline renderer for up to four ROM layers, one text layer
  and one sprite engine. No VRAM beyond 4 KB text RAM, no blitter, no
  zoom.

ALMs: not measured. On the comparison above, the unified build is
expected to land at or below Hyper Duel's 38%; this is an inference to
be replaced by the first M4 fit report. The split-build defines exist
for the case where it is wrong.

M10K: the RAM needed by the game hardware is small (4.3). Replacing
~307 blocks of VRAM with under 100 blocks of game RAM leaves large
headroom, enough to consider moving the Z80 program ROMs into BRAM if
SDRAM arbitration becomes awkward (not planned).

### 4.3 Memory budget per variant

BRAM (game-side RAM only; excludes CPU core internals, framework, line
buffers of about 4-6 KB, and FIFOs). Sizes from the memory maps in spec
3-4; sprite RAM counted twice (live + vblank copy).

| Variant | Work RAM | Sprite RAM x2 | Text RAM | Palette | Sound RAM | Total |
|---|---|---|---|---|---|---|
| lastday | 4 KB | 8 KB | 4 KB | 2 KB | 2 KB | 20 KB |
| gulfstrm | 4 KB | 8 KB | 4 KB | 2 KB | 2 KB | 20 KB |
| pollux | 4 KB | 8 KB | 4 KB | 4 KB (banked) | 2 KB | 22 KB |
| bluehawk | 4 KB | 8 KB | 4 KB | 2 KB | 2 KB | 20 KB |
| flytiger | 4 KB | 8 KB | 4 KB | 4 KB (banked) | 2 KB | 22 KB |
| primella family | 4 KB + 1 KB | none | 4 KB | 2 KB | 2 KB | 13 KB |
| rshark, superx | 60 KB | 8 KB | none | 4 KB | 2 KB | 74 KB |
| popbingo | 60 KB + 32 B regs | 8 KB | none | 4 KB | 2 KB | 74 KB |

A unified build instantiates the maximum of each column at once (60 KB
work RAM is only used by the 68000 games; the Z80 games use 4 KB of it).
Worst case about 80 KB, roughly 80 M10K at x16 width, before line
buffers.

SDRAM (ROM regions the core uses; region bytes from spec 13, which
include fill and unused space; gundl94's two unused regions excluded):

| Variant | Main | Sound | Text | Sprites | Tile + map | Colour ROM | OKI | Total |
|---|---|---|---|---|---|---|---|---|
| lastday | 128 KB | 64 KB | 32 KB | 256 KB | 768 KB + 256 KB maps | - | - | 1504 KB |
| gulfstrm | 128 KB | 64 KB | 32 KB | 512 KB | 768 KB + 256 KB maps | - | - | 1760 KB |
| pollux | 128 KB | 64 KB | 64 KB | 512 KB | 1024 KB + 256 KB maps | - | - | 2048 KB |
| bluehawk | 128 KB | 64 KB | 64 KB | 512 KB | 1280 KB | - | 256 KB | 2304 KB |
| flytiger | 128 KB | 64 KB | 64 KB | 512 KB | 1024 KB | - | 512 KB | 2304 KB |
| sadari | 128 KB | 64 KB | 128 KB | - | 1024 KB | - | 256 KB | 1600 KB |
| gundl94, primella | 128 KB | 64 KB | 128 KB | - | 512 KB | - | 256 KB | 1088 KB |
| superx, rshark | 256 KB | 64 KB | - | 2048 KB | 4096 KB | 512 KB | 256 KB | 7232 KB |
| popbingo | 256 KB | 64 KB | - | 1024 KB | 2048 KB | - | 256 KB | 3648 KB |

Every set fits a 32 MB SDRAM module with a single fixed layout:

| SDRAM base | Region | Max size |
|---|---|---|
| 0x000000 | main CPU ROM | 256 KB |
| 0x040000 | sound CPU ROM | 64 KB |
| 0x050000 | text chars | 128 KB (use 192 KB slot) |
| 0x080000 | OKI samples | 256 KB (flytiger region is 512 KB but only 128 KB is loaded) |
| 0x0C0000 | colour ROM (tmap_hi) or separate map ROMs (bg0_tmap, fg0_tmap) | 512 KB |
| 0x140000 | sprites | 2 MB |
| 0x340000 | bg0 | 1 MB |
| 0x440000 | bg1 | 1 MB |
| 0x540000 | fg0 | 1 MB |
| 0x640000 | fg1 | 1 MB |
| 0x740000 | end (7.25 MB address span; rshark/superx use 7232 KB of it) | |

(The OKI slot is sized to what the M6295 can address, 256 KB.) Fixed in
M0 by `tools/build_regions.py` exactly as tabled; the two separate map
ROMs go at aux +0 (bg0_tmap) and aux +0x20000 (fg0_tmap). Byte order: high
byte of each 16-bit word first.

Bandwidth, rough, per 64 us line at the MAME geometry:
- Z80 games: per 32x32 layer about 49 row fetches of 4 bytes plus 13 map
  words; text about 49 x 4 bytes; sprites up to 128 x 8 bytes. Worst
  case under 2 KB per line.
- 68000 games: per 16x16 layer about 25 x (8 bytes + map word + colour
  byte); sprites up to 256 x 8 bytes per 16-px strip in the worst case.
- A 16-bit SDRAM at 96 MHz has about 6,100 clock cycles per 64 us line,
  so at most that many word transfers at peak.
  The renderer should prefetch per line into BRAM (the Hyper Duel
  pattern); raw bandwidth is not the constraint, arbitration latency is.

### 4.4 Clock plan (proposal)

- Core clock 48 MHz: 8 MHz = /6, 4 MHz = /12, 1 MHz = /48, 1.5 MHz = /32
  exactly. 3.579545 MHz (bluehawk, flytiger YM2151) and 10 MHz
  (popbingo 68000) need fractional clock enables.
- SDRAM at 96 MHz (2x core), as in Hyper Duel.
- Pixel clock enable 8 MHz (16 MHz / 2) as the working assumption
  (spec 5.3, O3). Simulation uses MAME's 512 x 256 frame so the IRQ
  lines (Z80 vblank at 248, 68000 lines 120 and 248) land where MAME
  puts them. The shipped line/pixel totals are decided in M4 from R1
  evidence, with a 60 Hz option in the OSD as Hyper Duel does.

## 5. Milestones

Each milestone has a gate. Nothing moves on until the gate is green.

### M0. ROM validation and MAME oracle bootstrap

Inputs: ROMs from the MAME 0.289 merged set (downloading), MAME 0.289
with Lua.

1. `tools/check_roms.py`: read every zip, check file names, sizes and
   CRC32s against spec 13 (generate the expected table from
   `reference/mame/dooyong.cpp` directly, not by hand). Report missing,
   renamed and bad files. polluxn's BAD_DUMP is expected.
2. `tools/build_regions.py`: rebuild each MAME region exactly as the
   ROM_START block describes (16_BYTE lanes, WORD_SWAP, CONTINUE,
   RELOAD, FILL), then emit the SDRAM image in the 4.3 layout. Verify
   region images against MAME's own view by dumping regions from MAME
   (Lua `manager.machine.memory.regions`) and comparing byte for byte.
3. Answer the ROM-only questions:
   - O1: do lastday/gulfstrm/pollux map ROMs contain meaningful data
     beyond word 0x4000? (Entropy and tile-code range checks per 4 KB.)
   - O9: which map format each game selects (log register 6 writes).
   - T18: identify gundl94's cpu2/gfx4 ROMs if cheap; otherwise ignore.
4. MAME Lua taps (pin every tap handle in a global table; Hyper Duel
   lost taps to garbage collection and chased a phantom audio bug for a
   session, `docs/audio_bug_ym_irq_storm.md`):
   - every write to tilemap regs, ctrl regs, bank, sound latch, palette,
     text RAM and sprite RAM, with frame number and beam position
     (answers O10: are there mid-frame writes?);
   - per-frame dumps at vblank: sprite buffer, text RAM, palette,
     current tilemap regs, ctrl state;
   - YM2151/YM2203/OKI register writes on the sound CPU;
   - T2/T3/T4 ROM-area and unmapped writes, to characterise them;
   - per-frame screenshots of the visible area.
5. Python reference renderer (`sim/oracle/dy_render.py`) implementing
   spec 7-12 from the dumps. It must reproduce MAME's screenshots
   exactly for at least 300 attract-mode frames per parent before it is
   trusted. Any mismatch is a spec error: fix the spec first.

Gate M0: all 25 sets pass CRC (except the known BAD_DUMP); SDRAM images
built; the Python renderer matches MAME on every captured frame of
flytiger and bluehawk; the spec updated with O1/O9/O10 answers.

**M0 status (2026-09-27): DONE, gate PASS.** `cd sim && make m0` reproduces
it. 25/25 sets CRC/SHA1/size OK (polluxn BAD_DUMP noted); all regions of all
25 sets byte-identical to MAME's own region dumps; SDRAM images built;
`sim/oracle/dy_render.py` pixel-exact on 3,875/3,875 captured flytiger and
bluehawk frames (attract, including 600 consecutive frames each, and
flipped), and on 300 sampled frames of each other Z80 parent. O1: the
oversized map ROMs hold no extra map data (fill, and stale program code on
pollux fg0); register 2 is constant. O9: per-layer table in spec 7.3
(bluehawk fg1 uses format A). O10: pollux and all 68000 games write scroll
registers mid-frame every frame, so the RTL must latch video registers at
vblank for MAME parity (new R12). Differences from the plan above: MAME
0.288 was used as the oracle (the 0.289 ROMs verify in it); the renderer
covers the whole Z80 family but not yet the 68000 family; item 3 T18 got
only a cheap look (unidentified).

### M1. Video RTL parity

Modules (SystemVerilog, parameterised by game ID):
- `dy_timing`: counters, blanking, vblank edge, IRQ strobes.
- `dy_romlayer`: one ROM tilemap layer (tile size 32/16, rows 8/32, map
  format A/B, callback variants, colour ROM option, reg 0-7 semantics
  including the change-only write rule, flip per spec 11.10).
- `dy_text`: text layer, both byte layouts and both char formats.
- `dy_spr_z80`, `dy_spr_68k`: line-buffer sprite engines reproducing
  the first-drawn-wins rule and the pmask behaviour (spec 10.3).
- `dy_mix`: layer order and priority values per game (spec 11),
  palette lookup (both formats, bank), popbingo composite.
- `dy_palette`: CPU port + video port, format conversion.

Tests:
- Synthetic scenes vs the Python renderer (`make verify`), including
  flip, bank switching, sprites at every edge, both map formats.
- Replay of MAME dumps vs MAME screenshots (`make mame-verify`),
  frame by frame.

M0 inputs for M1 (see `docs/m0_findings.md` section 7): latch the tilemap
registers and video control bits at the start of line 248 and draw the
frame from the latched copy (MAME parity, spec 5.4); port the renderer's
rules one to one, including the flipped scroll closed form (spec 11.10);
replay the M0 frame dumps (`sim/mame/out/*/frames/*`) converted to
`$readmemh` files; add synthetic scenes for what the attract captures did
not exercise (flytiger sprite flips, bluehawk layer disable, flytiger
palette bank 0).

Gate M1: pixel-exact on all captured flytiger and bluehawk frames, and
on synthetic scenes covering every per-game flag in spec 10-11. Other
variants get the same gate when they are brought up.

**M1 status (2026-09-28): DONE for the Z80 family except primella, gate
PASS.** `cd sim && make m1-verify m1-synth` reproduces it. RTL in
`rtl/dy_*.sv` (one pass module for ROM layers and text, one Z80 sprite
engine; no separate `dy_timing` / `dy_mix` / `dy_palette` modules, those
live in `dy_video.sv`). 3,875/3,875 flytiger and bluehawk frames
pixel-exact against MAME; 408/408 synthetic scenes against the Python
renderer; lastday, gulfstrm, pollux 300/300 each against MAME. Worst line
4,305 of 6,144 clocks at 96 MHz with a pessimistic ROM port. Registers
latch at line 7 (end of vblank) for MAME's sprite/scroll pairing,
`docs/m1_findings.md` section 6. Not yet done: primella family
(no sprites, text priority, 256 visible lines) and the 68000 video
(`dy_spr_68k`, 16x16 layers, colour ROM), which also need the Python
renderer extended first.

### M2. Full-system boot in Verilator

- T80 main + T80 sound, bus decode per game, RAMs, SDRAM model with
  realistic latency, input replay from a file.
- Boot flytiger to attract mode and through at least one full attract
  loop. Compare against MAME per frame: screenshots, and checksums of
  work RAM, sprite RAM and palette.
- Expect timing drift against MAME: MAME's Z80 is cycle-counted but has
  no wait states; the real board's wait states are unknown. Where drift
  appears, align by event (first write of a known value) rather than by
  frame number, as Hyper Duel did for its 429-frame boot offset.
- Always-on gates in every boot run: SDRAM late-fetch count, renderer
  line-budget overruns, sprite engine overflow, unmapped-access log.

Gate M2: flytiger attract loop matches MAME frame for frame after event
alignment, zero gate counters, soak of 20,000 frames with zero gate
counters.

**M2 status (2026-09-28): DONE for flytiger and bluehawk, gate PASS.**
`cd sim && make m2-boot m2-soak`. Main Z80 (T80) + BRAM program ROM +
video from power-on through both attract loops: every captured frame is
either pixel-exact against MAME or pixel-exact against a line-accurate
model of the core's live text/palette reads (MAME draws the whole frame at
line 248); video RAM equals MAME's at every compared vblank apart from 5
one-frame transients; no alignment offset needed; ROM-area write counts
equal MAME's; 20,000-frame soak with zero overruns. Found and fixed: the
vblank sprite copy was not an instant snapshot. Sound CPU side moves to M3
as planned. Details in `docs/m2_findings.md`.

### M3. Sound

- jt51 + jt6295 (flytiger, bluehawk, primella family, 68000 games),
  YM IRQ to sound Z80 INT.
- Compare YM register write streams with MAME (order and values; timing
  within tolerance). Compare OKI command streams.
- Mix: YM2151 left and right at 0.35 each into mono, OKI at 0.42
  (spec 2, 1492-1495). Calibrate against MAME WAV captures. Hyper Duel
  note: the first sound can come many seconds into attract; size sim
  windows from MAME WAV timing, not from guesses.
- YM2203 games (in their variant slot, not before): 2x jt03, IRQs ORed
  as MAME does (T7), gain 0.40 on each chip's FM and three SSG outputs
  (MAME routes all four outputs of each chip). Keep the OR behind a
  parameter so a PCB-traced routing can replace it. Run gulfstrm's
  sound CPU at 8 MHz only if 4 MHz reproduces the "jerky music" the
  driver describes; record which was used and why (T8).

Gate M3: register-stream parity with MAME for 2 minutes of attract
audio per variant; level calibration within 1 dB of MAME's mix.

**M3 status (2026-09-28): flytiger and bluehawk sound running, level gate
PASS (+0.17 / +0.29 dB), stream parity PARTIAL.** Register streams are
identical for 47 s (flytiger) and 35 s (bluehawk), then the sound programs
diverge on timing-sensitive decisions; sound CPU timing, YM timer period and
M6295 status were each checked equal to MAME. New research item R13. 2026-10-03: unchanged by the jt6295 patches and the YM2151 write fix; the YM2151 busy flag is ruled out as a cause (m3_findings 6.2). 2026-10-03 later: explained. The divergence comes from a status read 8 us after a stop (frame 2,121): the MSM6295 datasheet (p. 73) says BUSY stays high until the next sample, so the read shows the channel busy (0xFB), where MAME shows it idle (0xFA); the sound program then takes a different path from frame 2,125. The core (jt6295 patch 3) follows the datasheet. Class: MAME wrong per datasheet (m3_findings 6.5). A MAME-timed status removes the divergence (equal to MAME past frame 2,400), which confirms the cause.
Details in `docs/m3_findings.md`.

### M4. MiSTer shell, SDRAM, Quartus

- Template_MiSTer shell, OSD (DIPs per spec 9, inputs, video options),
  ioctl download into the 4.3 SDRAM layout, game ID from the MRA.
- MRA per set (25), generated by a script from the spec 13 tables, with
  DIP defaults from spec 9 (0xFF/0xFF for most Z80 games, 0xFF/0xFD for
  the primella family, 0xFFFF for rshark/superx, 0xFFFB for popbingo).
- Screen rotation: 7 of 10 parents are ROT270. Use the framework's
  rotation support (DDR3 frame buffer path) as other vertical arcade
  cores do; confirm what the current Template offers before designing
  around it.
- Explicit RAM primitives from the start (hd_dpram/hd_tdpram).
- Quartus: one job at a time, launched through the scheduled-task
  method (not as an ssh child), per Hyper Duel's
  `plan_synthesis_and_bringup.md` section 0. Treat any build from the
  compile PC as suspect until its instability is resolved; confirm STA
  timestamps match the RBF.
- Decide video totals from R1 evidence (Native plus 60 Hz option).

Gate M4: STA clean on all clocks, fit report recorded (ALM, M10K), MRA
download-order test in sim (`make download` equivalent), 2,200-frame
SDRAM-model soak with hardware DIP settings and zero gate counters.

**M4 status (2026-09-28): gate PASS for flytiger/bluehawk, first RBF
deployed.** Compile 3 meets timing on every clock (core 96 MHz +0.802 ns);
43% ALMs, 291/553 RAM blocks; MRAs verified byte-exact; board sim through
the MRA stream + SDRAM model matches MAME; 2,200-frame hardware-timing soak
clean. Details in `docs/m4_findings.md`.

### M5. Hardware and MRAs

- Find the MiSTer by subnet scan (DHCP), deploy RBF + MRAs.
- QA checklist per game: boot, attract loop, coin/start, all buttons,
  DIPs including flip, service mode, sound balance by ear on a CRT,
  long play session.
- Photograph/record on hardware for any finding that differs from MAME;
  write it into `docs/ACCURACY.md` with evidence.
- Release order follows section 3; each variant ships when it passes
  its own M1-M3 gates and QA.

## 6. Research questions needing PCB evidence

Ordered by impact on the first two targets.

| ID | Question | Spec refs | Evidence that would settle it |
|---|---|---|---|
| R1 | Video timing: pixel clock, H and V totals, sync and blanking positions, true refresh | 5.3, T10, O3 | Scope on HSYNC/VSYNC, or high-frame-rate recordings of a board (Hyper Duel measured 60.24 Hz from recordings); the 15.68 kHz PCB figure suggests 510 clocks at 8 MHz |
| R2 | Sprite priority rule and sprite-vs-sprite order on real hardware | 10.3, T11, O5 | Recordings of overlapping sprites, and of colour 0/15 sprites passing under fg layers |
| R3 | Per-line sprite limit | O6 | Recordings of heavy sprite scenes for flicker or dropout |
| R4 | Sprite Y wrap and bluehawk +6 offset | O7, O8 | Recordings of sprites entering from the top edge |
| R5 | ROM tilemap regs 2, 5, 7 and the unreachable map ROM range | 7.2, T14, O1 | M0 ROM analysis first; then register-write logs against stage progress |
| R6 | flytiger ctrl bits 1-2; pollux bits 2 and 4; SYSTEM vblank bit for colour cycling (flytiger bit 6, pollux bit 4) | T13, T16 | Title/ending screen recordings (colour cycling present or not) |
| R7 | Bluehawk clocks (main, sound, YM2151 3.579545 or 4 MHz, OKI) | T20 | Crystal markings in PCB photos; pitch comparison of recordings |
| R8 | YM2203 IRQ routing and clocks on lastday/gulfstrm/pollux; sound CPU clock | T7, T8, T9, O2 | PCB trace of the two YM IRQ pins; crystal/divider identification; tempo comparison with the pollux reference video (line 63) |
| R9 | Writes to ROM space and I/O +0x18/+0x1A: watchdog or not | T2, T3, T4 | Board schematic fragments or a board test with the writes suppressed (not available to us; low priority, ignore as MAME does) |
| R10 | 68000 IRQ6 at line 120: source and exact line | T12 | Scope, or a game-behaviour test on hardware if a MiSTer build can vary it |
| R11 | Primella cocktail mode and buttons 2/3; Pop Bingo unknown registers | T5, T6 | Manuals, operator sheets, board owners |
| R12 | Do the boards latch tilemap scroll registers (and text/palette reads) at vblank? pollux and the 68000 games write scroll mid-frame every frame (68000: lines 120-135) | spec 5.4, O10, O11 | Recordings of superx/rshark/popbingo during scrolling (a tear near line 123 would mean no latch); pollux scrolling scenes |
| R17 | M6295 phrase end (does the chip play the second nibble of the stop byte?), a start command to a channel that is still playing (ignored or restart?), and how soon a stop shows in the status register | m3_findings 6 | OKI MSM6295 datasheet text on the phrase table stop address and on busy channels; a board test sending a start to a busy channel; recordings of games that re-send starts ; 2026-10-03: MSM6295 datasheet found (later edition, p. 73): BUSY timing after start and stop settled and implemented (jt6295 patch 3, m3_findings 6.5); start to a playing channel and a restart within one sample of a stop are not covered and follow MAME |

Community route: the forum post drafted on 2026-09-27 (memory note
`dooyong_mister_core.md`) can ask board owners for R1-R4 recordings.

## 7. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| ROM download incomplete or set names differ between MAME 0.289 and the master commit vendored here | M0 blocked | CRC-based matching in `check_roms.py`, name mapping per set |
| MAME is the oracle but has declared hacks (T7, T8, T10, T11) | Parity with MAME can mean parity with MAME's errors | Keep every hack behind a parameter; ship MAME behaviour by default and change only with evidence (Hyper Duel method) |
| Mid-frame register writes (O10) | Frame-level dump replay would miss raster effects | M0 beam-position logging decides whether M1 needs line-granular replay |
| Unknown real wait states / CPU timing | Boot drift vs MAME, possible game logic differences | Event alignment in M2; soak gates; hardware QA |
| Unified RBF does not fit or close timing | Delay at M4 | Split-build defines from day one |
| Compile PC instability | Untrustworthy builds, lost nights | One job at a time, scheduled-task launch, rebuild and compare on suspicion; resolve the hardware issue before M4 |
| Quartus RAM inference balloon | Multi-hour elaboration, fit failure | Explicit RAM primitives from the first RTL commit |
| Vertical games need rotation on HDMI | Extra framework work, DDR3 bandwidth | Use existing framework rotation; confirm in M4 before relying on it |
| polluxn BAD_DUMP, superxm borrowed graphics, gundl94 stray ROMs | MRA edge cases | Ship polluxn with a note or skip it; superxm MRA pulls graphics from the superx zip, as MAME does |
| An unannounced core by someone else | Duplicate effort | Forum post before heavy investment |
| MAME Lua tap handles collected silently | False conclusions from dead taps | Pin handles globally; assert tap liveness each frame |

## 8. First actions when ROMs land (all done in M0, 2026-09-27)

1. Copy the zips from the Transmission download folder into `roms/`.
2. Write and run `tools/check_roms.py` (M0.1).
3. Write `tools/build_regions.py` and compare regions with MAME (M0.2).
4. Run the O1 ROM analysis (M0.3) and update the spec.
5. Bring up the flytiger Lua taps and start the Python renderer.
