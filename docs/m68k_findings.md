# 68000 games: Super-X, R-Shark, Pop Bingo

Date: 2026-09-29/30. Game IDs 7 (superx, superxm), 8 (rshark, rsharka),
9 (popbingo). Spec 3.7, 5.2, 6, 7.4, 7.5, 10.2, 11.7, 11.9.

## 1. What changed

| File | Change |
|---|---|
| `sim/oracle/dy_render.py` | 68000 family: 16x16 layers (spritelayout, 64 x 32 maps, 1024 x 512) with the colour ROM, popbingo's composite (`0x100 | bg0 << 4 | bg1` from two raw 4-bit layers), the 68000 sprite list (256 entries last to first, row-major multi-tile, signed 9-bit Y, packed tiles), big-endian palette and sprite words. 300/300 frames pixel-exact against MAME on each game |
| `rtl/dy_layer_pass.sv` | 16x16 tiles, colour ROM bytes, 13-bit codes, 9-bit Y on the 512-line maps, colour base up to pen 1279; a per-layer map-row cache (map words and colour nibbles only change every 16 or 32 lines) |
| `rtl/dy_spr_z80.sv` | 68000 mode: 1,024 buffer reads per line (4 per entry), hit test per sprite row, a fetch stage that expands a row into width + 1 tiles and skips tiles wholly off screen, packed pixel decode, colour base 0, per-game code wrap (8,192 tiles on popbingo, 16,384 on superx/rshark) |
| `rtl/dy_video.sv` | four ROM layers (bg1 added), 68000 pass order with bg2 priority (ctrl bit 4), popbingo composite with a second pen buffer, IRQ6 at line 120, 16-bit big-endian CPU ports with byte enables, sprite list from the previous vblank on these games (section 3), renderer allowed to run three lines ahead (four output line buffers) |
| `rtl/dy_sys.sv` | fx68k main CPU (vendored from Hyper Duel with its Verilator patches, `rtl/vendor/fx68k/PROVENANCE.md`) at 8 MHz (10 MHz popbingo) from two-phase fractional enables; bus FSM without wait states; IRQ5 at line 248 and IRQ6 at line 120, HOLD_LINE, autovectored (VPA); the three memory maps; one 128K x 16 program ROM and one 32K x 16 work RAM shared with the Z80 games; YM2151 at 4 MHz |
| `rtl/dy_board.sv` | main program range 256 KB (0x000000-0x03FFFF) |
| `tools/make_mra.py` | 5 MRAs, DIPs from the driver (superx SWA:1 unknown, popbingo inverted demo sounds, VS Max Round, Blocks Don't Drop; popbingo default DSWA 0xFB) |
| `Arcade-Dooyong.sv`, `.sdc`, `files.qip` | ROT270 for superx/rshark, Button 3 on P1/P2 bit 6; fx68k in the project with Hyper Duel's intra-core multicycle |

## 2. Results

| Check | superx | rshark | popbingo |
|---|---|---|---|
| M1 replay vs MAME (300 frames) | 300/300 | 300/300 | 300/300 |
| M1 targeted + random scenes | 32 + 60 | 32 + 60 | 26 + 60 |
| Worst render line (pessimistic ROM model) | 4,451 clocks | 6,754 (absorbed by the run-ahead, 0 overruns) | 2,023 |
| M2 boot from power-on vs MAME | exact to frame ~690 | exact to frame ~540 (small transient differences), streams identical to frame 1,481 | see section 4 |
| Sound level vs MAME WAV | within 1 dB | within 1 dB | rerun pending (section 4) |

All Z80-game suites re-run after these changes: M1 unchanged, flytiger and
bluehawk M2 boots 0 unexplained frames and 0 persistent RAM differences.

## 3. Sprite list pairing

The 68000 games write their scroll registers in the line-120 IRQ6 handler
(lines 120-135, spec 5.4). MAME draws frame N at line 248 with those
registers and the sprite list copied at vblank N-1. The register latch at
line 7 picks up frame N's registers, so the display after vblank N draws the
sprite list of vblank N-1 from the second half of the buffer: the displayed
frame N equals MAME's frame N (M2 offset 0). On a board that does not latch
the registers (R12, unknown), the lines below the write line show exactly
this pairing.

## 4. Divergence from MAME (research item R16)

The main CPU's I/O writes match MAME's log in order and value, but the
IRQ6 handler's writes land 7-8 pixels (about 7-8 CPU cycles) later than in
MAME, varying frame to frame (some frames earlier). That is the interrupt
acknowledge cycle: the board autovectors (VPA), and a real 68000 then runs
an E-clock synchronised cycle of variable length, which fx68k models; MAME's
68000 times that cycle differently. The games run in step until one of
those shifts changes an outcome (superx ~frame 690, rshark ~1,480,
popbingo early, see below), the same class as R15 on the Z80 games. The
core keeps fx68k's behaviour (hardware accuracy over MAME parity).

popbingo's first gate run used DSWA 0xFF while MAME's default is 0xFB
(demo sounds switch inverted, i.e. demo sounds on in MAME): its audio and
early divergence are being re-checked with the MAME defaults.
