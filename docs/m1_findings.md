# M1 findings: video RTL parity (Z80 family)

Date: 2026-09-28. Scope: flytiger and bluehawk (the M1 gate), plus lastday,
gulfstrm and pollux, which share the same video path. Primella family and
the 68000 games are not in this RTL yet.

Reproduce: `cd sim && make m1-build m1-verify m1-extra m1-synth` (needs
`make regions` and the M0 captures in `sim/mame/out`). About 90 s for the
gate on this Mac (all cores).

## 1. Gate

| Gate item | Result | Evidence |
|---|---|---|
| Pixel-exact on all captured flytiger and bluehawk frames | PASS | `make m1-verify`: flytiger_attract 1,625/1,625, flytiger_flip 300/300, bluehawk_attract 1,650/1,650, bluehawk_flip 300/300, all against MAME's snapshots |
| Synthetic scenes covering the per-game flags (spec 10-11) | PASS | `make m1-synth`: 408/408 scenes pixel-exact against `sim/oracle/dy_render.py` (section 3) |

Every frame is checked twice: the RTL's RGB against the MAME snapshot
(rotated for ROT270), and the RTL's pen index against the reference
renderer's pen. Pens the game never wrote show MAME's power-on colour
(spec 6.3); for those pixels the RTL pen is looked up in `pens.bin`, the same
rule `compare_frames.py` uses. The checker was seen to catch a real bug
(section 5).

Beyond the gate: `make m1-extra` gives lastday 300/300, gulfstrm 300/300 and
pollux 300/300 against MAME, which covers the separate map ROMs, xBGR_444,
the text Y scroll and pollux's palette bank.

No line overran its budget in any run (section 4).

## 2. What was built

| File | Content |
|---|---|
| `rtl/dy_pkg.sv` | per-game configuration from the game ID (layer bases, masks, colour bases, map offsets, text layout, sprite flags, palette format) in the PLAN 4.3 SDRAM layout |
| `rtl/dy_video.sv` | timing (512 x 256, visible 64-447 / 8-247, vblank IRQ at 248), tilemap registers with the vblank latch, palette / text / sprite RAMs with byte-wide CPU ports, sprite-list copy at vblank, line renderer control, ROM arbiter, resolve, scan-out |
| `rtl/dy_layer_pass.sv` | one ROM tilemap layer or the text layer over one line: issue, return and pixel stages overlapped |
| `rtl/dy_spr_z80.sv` | Z80 sprite engine: scan, fetch and draw stages overlapped, first-drawn-wins line buffer, two pixels per clock |
| `rtl/dy_dpram.sv` | Hyper Duel's `hd_dpram` renamed (Verilator arrays, altsyncram in Quartus) |
| `sim/m1/tb_video.cpp` | Verilator C++ harness: loads each frame through the CPU ports with the pixel clock stopped before line 248, runs one full frame, captures the scanned-out pixels |
| `sim/m1/replay.py` | converts oracle frame dirs to harness input, runs batches in parallel, checks every frame |
| `sim/m1/make_scenes.py` | synthetic scenes |

Per line L, during line L-1: the tilemap passes run in the game's order
(spec 11) while the sprite engine fills its own line buffer; then a resolve
pass applies the masks (colour 0/15 sprites hidden where the priority value
is 2 or more, others where it is 4 or more) and writes the finished line to
a double buffer. Scan-out reads that line and the palette at the pixel
enable.

The graphics ROM port is pipelined and in order (accepted on req && gnt,
data returned later with a valid strobe). The layer pass and the sprite
engine share it through a round-robin arbiter with an owner FIFO.

## 3. Synthetic scenes

`sim/m1/make_scenes.py`, fixed seed, checked against the reference renderer:

| Run | Scenes | Content |
|---|---|---|
| flytiger_targeted | 28 | sprite X/Y flips on every sprite (normal and screen flip), palette bank 0 with content, priority swap inverted, map format B on bg0 and on fg0, sprite X 0x1F0-0x1FF, left-edge clipping, negative Y shift straddling the top, heights 1-8 with flips, colour 0/15 sprites, scroll extremes (reg0/reg1/reg3 = 0xFF etc.) with and without flip |
| bluehawk_targeted | 20 | each layer disabled alone and all three, format A on bg0, the sprite placement and scroll sets above with bluehawk's Y shift |
| lastday/gulfstrm/pollux/flytiger/bluehawk_random | 60 each | random registers, formats, disable bits, flip, palette bank, priority swap, lastday sprite disable, random palette, text and sprite RAM |

These cover the features the attract captures did not (m0_findings 3):
flytiger sprite flips, bluehawk layer disable, flytiger palette bank 0.

## 4. Line budget

Harness ROM model: one 32-bit read accepted every 8 clocks, data 9 clocks
later. At a 96 MHz renderer clock that approximates a close-page 16-bit
SDRAM with no bank overlap (Hyper Duel's controller policy at 80 MHz), so it
is a pessimistic port. Budget = 512 pixels x 12 clocks = 6,144 clocks per
line.

| Case | Worst line |
|---|---|
| flytiger captures (includes boot frames with all 128 sprites on lines 8-15) | 4,193 clocks |
| bluehawk captures | 2,800 |
| stress: bluehawk, three layers + text + 128 sprites 8 tiles tall on the same lines | 4,305 (70% of budget) |
| same stress at 48 MHz, port 1 read / 4 clocks, latency 5 | 2,361 of 3,072 |

The first version (one request in flight, sequential passes, one sprite
pixel per clock) needed 6,799 clocks on the 128-sprite lines at 48 MHz
and latency 6, so it could not meet a real budget. It was pixel-exact too
(3,875/3,875 with a relaxed budget) and was replaced by the pipelined
design above, which is the one the gate numbers refer to.

The CPUs will also fetch from SDRAM in M2. The Z80 program ROMs could move to
BRAM if that bandwidth is needed (PLAN 4.2 has the headroom).

## 5. Bug found by the harness

The output line double buffer was declared with 768 entries but indexed
`{parity, x}`, which spans 1,024; odd lines lost every pixel at x >= 256.
Only frames with content there showed it (flytiger frame 1 of the canary,
7,633 pixels). Fixed by sizing the array to 1,024.

## 6. Decision needed before M2: sprite / scroll frame pairing

MAME draws frame N at line 248 from the registers at that moment and from
the sprite buffer copied at the previous vblank, then copies the live sprite
RAM (spec 5.3, 10.1). So each MAME frame pairs regs(N) with sprites(N-1).

The RTL as built latches the registers at line 248 (the PLAN M1 rule,
`LATCH_LINE` parameter) and copies the sprite list at line 248, then shows
both during the next active period: regs(N) with sprites(N). The M1 replay
cannot see this because it loads the dumped buffer directly. In M2, a
frame-by-frame comparison with MAME would show sprites one frame ahead of
the scroll in scenes where both move.

Two ways to get MAME's pairing:

- A. Latch the registers at the end of vblank (line 7) instead of 248. The
  displayed frame is then MAME's frame N+1 exactly whenever the game writes
  the registers only in vblank (bluehawk always; flytiger all but 44 changes
  in 12,000 frames), with no added delay. Writes during the active lines
  (pollux, and the 68000 games' line-120 handler) would show one frame later
  than in MAME.
- B. Keep the 248 latch and draw from a second sprite buffer (ping-pong,
  +4 KB BRAM). Always MAME's pairing, but the whole picture is one frame
  later than the real board could show it.

Recommendation: A for the Z80 games (no added latency, exact on bluehawk),
decided per family with the M2 comparison; the 68000 games need the R12
evidence either way. `LATCH_LINE` is already a parameter; A is a one-line
change.

## 7. Notes for M4 (synthesis)

- Line buffers are written as arrays with registered reads, so they can map
  to M10K: layer pens 384 x 11, sprite pens 2 x 192 x 12, output 1,024 x 12.
  The per-pixel flags (layer valid, three priority bits, sprite occupancy,
  5 x 384 bits) are flops.
- Nothing has been through Quartus yet; the 96 MHz renderer clock is an
  assumption to confirm with timing analysis.
