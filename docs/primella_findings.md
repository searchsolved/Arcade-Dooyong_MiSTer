# Primella family: Sadari, Gun Dealer '94, Primella

Date: 2026-09-29. Game IDs 5 (sadari) and 6 (gundl94 and its clone
primella, which share region sizes). Spec 3.6, 5.3, 6, 7.5, 9, 11.6.

## 1. What changed

| File | Change |
|---|---|
| `rtl/dy_pkg.sv` | `G_SADARI`, `G_GUNDL94`, `is_primella()`; layer config: map in the top 32 KB of each tile region (word offset -0x4000), 1024 tiles per layer on sadari, 512 on gundl94; packed text, 4096 chars, byte-interleaved CPU layout |
| `rtl/dy_video.sv` | primella timing: all 256 lines visible, vblank IRQ at line 256 (= line 0 of the next frame in the 256-line parity frame, never at power-on), register latch at the start of the last line (when line 0 is rendered); pass order bg0, [text], fg0, [text] by ctrl bit 3; sprite engine not started |
| `rtl/dy_sys.sv` | primella map: C000 work RAM, D000-D3FF extra 1 KB RAM (T15), E000 text, F000-F7FF palette write-only (reads 0), F800 DSWA / ctrl (bank bits 0-2, text priority bit 3, flip bit 4), F810 DSWB / sound latch, F820 P1, F830 P2, F840 SYSTEM, FC00-FC07 bg0, FC08-FC0F fg0 |
| `rtl/dy_snd.sv` | YM2151 clock select: 4 MHz on the primella family (16 MHz / 4), 3.579545 MHz otherwise |
| `Arcade-Dooyong.sv` | Button 3 (J1 bit 9, keyboard LShift / Q) on P1/P2 bit 6 for sadari only; other games keep bit 6 at 1 as in MAME |
| `tools/make_mra.py` | 3 new MRAs with the driver's DIPs (Show Girl, Cabinet, sadari Girl Show Point; default DSWB 0xFD) |
| `tools/deploy_mister.sh` | copies sadari.zip and gundl94.zip |
| sim | M1 harness and replay for 256-line frames; synthetic scenes for the family; M2 compare and M3 stream compare with the vblank at line 0; `make m2-primella`, `make m3-wav-primella` |

## 2. Results

| Check | sadari | gundl94 |
|---|---|---|
| M1 replay vs MAME snapshots (300 sampled attract frames) | 300/300 exact | 300/300 exact |
| M1 targeted scenes (flip x text priority, layer disable, format A, scroll extremes) vs dy_render | 30/30 | 30/30 |
| M1 random scenes vs dy_render | 60/60 | 60/60 |
| M2 boot, 9,001 frames from power-on | 258 exact + 42 line-exact (live reads), 0 unexplained | 228 exact + 72 line-exact, 0 unexplained |
| RAM dumps (palette, text) at 300 vblanks | 600/600 match | 600/600 match |
| YM2151 register stream | 58,499 writes identical, drift 0..1 line | 55,128 identical, 0..1 line |
| M6295 command stream | 260 identical; one group of 3 at frame 7714 is 54 lines early (section 3) | 269 identical, 0..1 line |
| Board sim (MRA stream, dy_sdram + SDRAM model, 96 MHz), 1,201 frames | 36 exact + 4 line-exact, 0 unexplained; 80/80 RAM; 0 overruns, worst line 2,030 clocks | - |
| Audio level vs MAME WAV | within 0.35 dB, envelope correlation 0.89 | within 0.9 dB, 0.91 |

Render time: worst line 1,801 of 6,144 clocks (two ROM layers and text,
no sprites). Other games unchanged: M1 all suites re-run, all pass (flytiger_attract
1,625/1,625); flytiger board boot re-run (`make m4-boot`).

The attract captures never flip the screen or disable a layer, and gundl94
never sets the text priority bit; the targeted scenes cover those.

## 3. Open items

- **R14 (new): primella display timing.** MAME shows all 256 lines with
  vblank at line 256 (the config's visible area, spec 5.3). The core
  follows it for parity, so on hardware (260 lines) there are only 4 blank
  lines, with vsync at lines 257-258. The HDMI scaler accepts this; analog
  15 kHz output is untested. The games' artwork suggests a 240-line
  picture (borders in the top and bottom 8 lines), so the real board
  probably blanks lines 0-7 and 248-255 like the other Dooyong boards.
  Needs a PCB recording; an OSD crop option is the fallback.
- **sadari OKI timing at frame 7714.** The main CPU writes command 0x04 to
  the sound latch at line 6; our sound CPU acts on it 2 lines later, MAME's
  55 lines later. Command values and order are identical before and after,
  and no other of the 529 M6295 commands drifts by more than a line. It
  looks like MAME's scheduling quantum delaying the latch; treat as MAME
  artefact unless heard on hardware.
- T15 (the D000-D3FF RAM) stays unexplained; it is plain RAM here as in
  MAME.

Hardware (2026-09-29): Dooyong_20260929.rbf (md5 04fa2a61, timing +0.518 ns) deployed with the Sadari, Gun Dealer '94 and Primella MRAs; Lee: "switched on and working".
