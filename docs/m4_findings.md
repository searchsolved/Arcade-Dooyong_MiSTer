# M4 findings: MiSTer shell, SDRAM, MRA, Quartus

Date: 2026-09-28. Scope: flytiger and bluehawk (game IDs 3 and 4).

## 1. Built

| File | Content |
|---|---|
| `rtl/dy_sdram.sv` | SDRAM controller for three clients (download words, 2-word graphics reads on dy_video's pipelined port, OKI byte reads) plus refresh. Close-page, CL2, capture 3 clocks after CAS, full-word writes only (the MiSTer SDRAM board ties DQM low), tRCD/tRP 3 clocks at 96 MHz (the modules' AS4C32M16SB-7 needs 21 ns; 2 clocks would be 20.8 ns). Protocol and constants from Hyper Duel's hardware-proven controller |
| `rtl/dy_board.sv` | everything below the framework: dy_sys + dy_sdram + ioctl handling (index 0 ROM stream = SDRAM image, program ranges also copied into BRAM; index 1 game ID; index 254 DIPs); core held in reset during downloads and until the SDRAM is initialised |
| `Arcade-Dooyong.sv` | Template_MiSTer `emu`: hps_io, inputs (spec 9.2), dy_board at 96 MHz, arcade_video, screen_rotate (MISTER_FB=1) for the ROT270 games, aspect 3:4 rotated |
| `Arcade-Dooyong.qsf/.sdc/.qpf/.srf`, `files.qip`, `pll.v`, `pll/`, `sys/` | Quartus project; qsf settings and sys/ copied from Hyper Duel (BALANCED, timing-driven synthesis off); PLL 96 MHz + 96 MHz at -90 degrees (-2,604 ps) for SDRAM_CLK; multicycle 2 inside the clock-enabled T80s, jt51 and jt6295 |
| `tools/make_mra.py` | generates the MRAs from the driver's ROM_START blocks and proves each one: a Python replay of Main_MiSTer's mra_loader.cpp assembly (part/interleave/map/repeat rules read from its source) rebuilds the stream from the zip, compared with sdram.bin byte for byte |
| `releases/mra/*.mra` | 5 MRAs (Flying Tiger sets 1-2, Blue Hawk and its two NTC sets), all verified |
| `tools/deploy_mister.sh` | finds the MiSTer by MAC, copies RBF, MRAs and ROM zips if missing, MD5 on both sides, never overwrites |
| `sim/m4/tb_board.sv`, `tb_board.cpp`, `sdram_model.sv` | board simulation: the MRA stream through ioctl into dy_sdram and Hyper Duel's SDRAM model (flags protocol errors), 96 MHz |

Video timing on hardware: 8 MHz pixel clock (96 MHz / 12), 512 x 260 = 60.10
Hz. Simulation keeps MAME's 512 x 256 at 60.00 Hz for the MAME comparisons.
Real totals remain research item R1.

## 2. Simulation results

| Check | Result |
|---|---|
| MRA streams | 5/5 byte-identical to the SDRAM images |
| Board boot, MAME parity timing (`make m4-boot`) | 1,200 frames from power-on through the 7.6 MB download and the SDRAM model: 83 frames exact vs MAME, 67 line-exact against the live-read model (m2_findings 3), 0 unexplained; all 452 RAM dumps match; no SDRAM protocol errors; 0 line overruns, worst line 4,697 of 6,144 clocks with the real controller |
| Board soak, hardware timing (V_TOTAL 260, integer 8 MHz) | 2,100 frames, 0 overruns (run stopped for the timing fixes below; to repeat on the final RTL) |

## 3. First Quartus build: timing failure and fixes

Compile 1 (Quartus 17.0 Lite on the compile PC, E-cores): synthesis, fit and
assembly clean, but setup slack -2.165 ns on the 96 MHz core clock (TNS
-1,730 ns); all other clocks met. Not deployed.

The 400 worst paths were two structures:
- 394: CPU address -> palette/text/sprite address mux -> 1,024-to-1 lookup
  of the sprite copy's `copied` bitmap -> 487 write enables, in one clock.
  Fix: the sprite-RAM write is pipelined (register the write, look up the
  bit the next clock, save and read the old word the clock after, write the
  live RAM at the third clock).
- 6: the sprite engine's record queue (a RAM block) feeding the pixel
  logic. Fix: latch the head record into registers at draw start and split
  the pixel step into two stages.

After the fixes: M1 all suites unchanged (3,875/3,875, 900/900, 408/408).

## 4. Compiles 2 and 3

Compile 2: -0.232 ns, 73 failing paths:
- 51: the copy engine's own lookup of the `copied` bitmap at its running
  counter, decided and written back in the same clock. Fix: the bitmap
  now only records CPU saves during the copy (cleared at vblank); the
  engine's lookup is registered one clock ahead, in step with its live-RAM
  read, and a save is only needed for words at or beyond the copy counter.
  (A one-bit generation scheme in RAM was tried first and broke M1: marks
  never written read as saved every other frame. Reverted.)
- 21: the framework's HQ2x scaler inside arcade_video cannot run at 96 MHz.
  Fix: a third PLL output, 48 MHz phase aligned, drives arcade_video and
  screen_rotate; the core's pixel outputs (changing every 12 core clocks)
  are re-registered there and sampled by a divide-by-6 enable.
- 1: the scan-out read of the output line buffer was conditional, which
  kept it out of block RAM. Now unconditional, blanked one stage later.

Compile 3: timing met on every clock (0 negative slack entries):

| Clock | Setup | Hold |
|---|---|---|
| core 96 MHz | +0.802 ns | +0.256 ns |
| video 48 MHz | +3.091 ns | +0.243 ns |

Fit: 18,140 / 41,910 ALMs (43%), 291 / 553 RAM blocks (53%), 2.25 Mbit
block memory (40%). RBF `builds/Dooyong_20260928.rbf`, MD5
c2a73ac3e531ba471670b4dc5e12186a (same on the compile PC), timestamp from
the compile-3 flow (21:30:07, flow end 21:30:27).

M1 re-run on the compile-3 RTL: all suites pass (3,875/3,875 gate,
408/408 synthetic). M2 flytiger 7,500-frame re-run and the hardware-timing
board soak: section 5.

## 5. Final checks on the compile-3 RTL, deploy

| Check | Result |
|---|---|
| M2 flytiger re-run, 7,500 frames (covers the vblank-7408 sprite-copy case) | 1,296 exact vs MAME, 166 line-exact against the live-read model, 0 unexplained; RAM: 2 transient, 0 persistent |
| Board soak, hardware timing (260 lines, exact 8 MHz), 2,200 frames | 0 overruns, worst line 4,698 of 6,144 clocks |

Deployed 2026-09-28 22:20 to the MiSTer (found by its MAC address) with
tools/deploy_mister.sh, new files only, MD5 checked both sides:
`_Arcade/cores/Dooyong_20260928.rbf`, the 5 MRAs in `_Arcade/`, and
`games/mame/flytiger.zip`, `bluehawk.zip`. Hardware result: pending the
first test (M5).
