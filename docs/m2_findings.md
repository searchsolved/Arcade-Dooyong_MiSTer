# M2 findings: full-system boot in Verilator (main CPU side)

Date: 2026-09-28. Scope: flytiger and bluehawk main systems (main Z80,
program ROM, work RAM, bus decode, control registers, inputs, video). The
sound CPU side is M3; the main CPU only writes the sound latch and never
reads it back (spec 4), so it runs identically without it.

Reproduce: `cd sim && make m2-build m2-boot m2-soak` (about 35 min for
`m2-boot` with both games in parallel, 75 min for the soak, on this Mac).

## 1. Gate

| Gate item | Result | Evidence |
|---|---|---|
| flytiger attract matches MAME frame for frame | PASS | 8,800 frames from power-on (two attract loops); 1,624 captured frames: 1,451 pixel-exact against MAME, 173 differ from MAME only through live reads and are pixel-exact against the line-accurate model (section 3), 0 unexplained |
| bluehawk attract (beyond the plan) | PASS | 9,000 frames; 1,649 captured: 1,523 exact, 126 line-exact against the model, 0 unexplained |
| CPU state parity | PASS | palette, text and sprite RAM compared with MAME's dumps at 1,625 (flytiger) and 1,650 (bluehawk) vblanks: no persistent difference; 5 transient, vblank 1 excluded (section 4) |
| ROM-area writes (spec 3.8, T2) | PASS | flytiger 2,372 writes, bluehawk 2, both equal to MAME's write logs over the same frames |
| Gate counters zero | PASS | line overruns 0 in every run; worst line 2,313 of 3,072 clocks (48 MHz sim clock); bankswitch writes with bits 3-7 set: 0 |
| 20,000-frame soak | PASS | flytiger, 20,000 frames, overruns 0 |

No event alignment was needed: our vblank N is MAME's frame N from power-on
(MAME's CPU and ours both start at time 0 and the frame is 512 x 256 at
exactly 60 Hz in both, section 2).

## 2. What was built

| File | Content |
|---|---|
| `rtl/dy_sys.sv` | main system: T80s at 8 MHz, program ROM in BRAM (download port), 4 KB work RAM, flytiger and bluehawk decode (spec 3.4, 3.5), bank, control, sound latch (exported), inputs, vblank IRQ held until acknowledged with 0xFF on the bus, dy_video |
| `rtl/vendor/t80/` | T80 from jotego/jtcores at a fixed commit: VHDL for Quartus, jtframe's GHDL-generated `T80s.v` for Verilator (one CPU implementation in both), `PROVENANCE.md` |
| `sim/m2/tb_sys.cpp` | harness: downloads the program ROM, runs from reset, captures requested frames (image, video RAMs at vblank, a log of every CPU write to 0xC000-0xFFFF with beam position), input replay (`+inputs=`) |
| `sim/m2/compare.py` | comparison with the MAME oracle run, including the line-accurate model |
| `sim/m2/run_boot.sh` | one boot run |

Clocking: CPU enable = system clock / CPU_DIV (8 MHz); pixel enable from a
fractional divider giving exactly 512 x 256 x 60 = 7,864,320 pixels per
second. A plain 8 MHz pixel clock would give 61.04 Hz and a different
CPU-cycles-per-frame count from MAME's, so the programs would drift apart.
The simulation runs the system clock at 48 MHz for speed (0.23 s per frame,
single thread); hardware runs 96 MHz. Real video totals are still an M4
decision (R1).

Program ROM in BRAM: zero wait states, as MAME's Z80 has none, and no SDRAM
arbitration with the renderer. 128 KB main ROM (plus 64 KB sound ROM in M3)
fits the M10K budget in PLAN 4.2.

## 3. Live reads: why some frames differ from MAME, and how they are checked

MAME draws each frame in one go at line 248 from the final RAM and register
values. The core, like any board without a frame buffer, reads text RAM
while it renders each line and the palette while it scans each line out.
The games write text RAM during the active lines in many frames (for
example flytiger's blinking INSERT COIN colour at about line 76, bluehawk's
scrolling ranking table), so part of our frame shows the old value and
part the new one, while MAME shows the new one everywhere. Registers are
latched at line 7 (m1_findings 6); a value-changing register write during
the active lines (7 flytiger frames here) shows in MAME's frame and not in
ours.

These frames are not accepted on sight. For each one, `compare.py` builds
a line-accurate model from our own RAM dumps at vblank N (which match
MAME's) plus the logged writes with beam positions: text RAM as it is while
line y is rendered (during line y-1), palette as it is while line y is
scanned out, registers as latched at line 7 (from MAME's write log), and
the sprite list as copied at vblank. `dy_render.py` draws each line from
that state. Writes inside a line's read window may land either side of the
read of each cell, so every intermediate state inside that window is
accepted. Every one of the 299 frames is pixel-exact against this model.

Whether real boards read text and palette live is the same open question
as R12. The live behaviour is what the hardware almost certainly does (it
would need a second 4 KB copy otherwise); MAME's whole-frame draw is an
emulation shortcut.

## 4. Transient RAM differences

At 5 of the 3,275 compared vblanks, 1 or 2 text RAM bytes differ from
MAME's dump, and the next compared vblank matches again. These are writes
landing a few CPU cycles either side of the vblank instant, from small
per-instruction timing differences between T80 and MAME's Z80. At vblank 1
our CPU is 22 byte-writes behind MAME inside a text-clearing loop at
power-on; it is in step from the first vblank wait on (vblank 9 onward).

## 5. Bug found: the sprite-list copy was not a snapshot

The first M2 run had one frame (flytiger 7408) where 74 pixels matched
neither MAME nor the model: a sprite pixel at lines 240-247. The vblank
copy moved 4,096 bytes one per clock, about 85 us, and the vblank handler
wrote sprite RAM (0xC9E2 at line 248, pixel 304) before the copy reached
that byte, so the buffer took the new value. MAME's BUFFERED_SPRITERAM8 is
an instant copy.

Fix in `dy_video.sv`: live sprite RAM and the buffer are both 1024 x 32;
CPU writes to the live RAM are delayed two clocks; during the copy a CPU
write to a word not yet copied first saves that word's old value into the
buffer (the copy engine gives up its read port for one clock and skips the
word later). The buffer is now exactly the live RAM at the start of line
248, with no CPU stall. After the fix: M1 all green again, frame 7408 exact
against MAME, gate as in section 1.

The harness sprite dump was updated for the 32-bit RAM; one gate run made
before that update produced invalid sprite dumps and was discarded.

## 6. Not done in M2

- Input replay exists (`+inputs=`) but no coin/start sequence has been
  compared with MAME yet (needs an oracle capture with the same inputs).
- lastday, gulfstrm, pollux main-system decode (their video already passes
  M1); they come with their YM2203 sound in the M3 slot of PLAN 3.
- SDRAM: graphics ROMs use the harness model; the real controller is M4.
