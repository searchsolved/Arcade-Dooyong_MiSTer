# YM2203 games: Last Day, Gulf Storm, Pollux

Date: 2026-09-29. Game IDs 0 (lastday, lastdaya, ddaydoo), 1 (gulfstrm and
4 clones), 2 (pollux and 3 clones). Spec 2, 3.2, 3.3, 4, 5.1, 9.

## 1. What changed

| File | Change |
|---|---|
| `rtl/vendor/jt03/` | jt03 (YM2203) and jt49 (its SSG) from jotego/jt12 dc9be7c + jt49 7f6abfd, unchanged, GPL-3 (PROVENANCE.md) |
| `rtl/dy_snd.sv` | YM2203 mode: two jt03, INT = OR of both IRQs (MAME's input merger, T7), port A reads 0; lastday/gulfstrm map (ROM 0000-7FFF, RAM C000, latch C800, YMs F000/F002) and pollux map (ROM 0000-EFFF, RAM F000, latch F800, YMs F802/F804); YM2203 4 MHz (lastday) or 1.5 MHz; sound CPU 8 MHz on gulfstrm; FM held at 0 until each chip's first write (section 3); mix gains fitted against MAME |
| `rtl/dy_sys.sv` | lastday map (C000-C014 I/O and tilemap regs, C800 palette, D000 text, E000 work RAM, F000 sprites) and gulfstrm/pollux map (C000 work RAM, D000 sprites, E000 text, F000-F027 I/O, F800 palette, banked on pollux); ctrl bits (lastday flip 6, sprite disable 4; gulfstrm/pollux flip 0, pollux palette bank 1); per-game SYSTEM ports rebuilt from the generic one, lastday tilt active high; gulfstrm reads P2 at F002 and P1 at F003; MAME's 2.5 ms vblank as SYSTEM bit 4 on gulfstrm and pollux |
| `tools/make_mra.py` | 12 MRAs (all sets of the three games) with lastday and gulfstrm DIPs; all 20 MRAs verify byte-exact |
| `tools/deploy_mister.sh` | optional MRA list, so a build only gets the MRAs it runs |
| `sim/mame/dy_oracle.lua` | pollux YM taps moved to F802-F805 (the gulfstrm config it copied tapped sound RAM); optional work RAM dump |
| `docs/dooyong_system_spec.md` | section 3.3 corrected: it listed bluehawk's I/O addresses for gulfstrm/pollux; bluehawk now has its own 3.4 |
| sim | compare.py live-read model and register latch for the three maps; compare_snd.py YM2203 streams; fit_opn.py gain fit; harness `+opnwav`, `+sysrd` |

## 2. Results (9,001 frames from power-on, 300 MAME snapshots each)

Final RTL (power-on phase, T80 IX/IY, mix fix; section 4):

| Check | lastday | gulfstrm | pollux |
|---|---|---|---|
| Images | 295 exact + 5 line-exact, 0 unexplained | 244 + 56, 0 unexplained | exact or line-exact until the split at frame ~706 (R15, section 5) |
| RAM dumps (palette, text, sprites) | 900/900 | all match until frame 8,970 | all match until frame ~706 |
| Work RAM (every 30 frames) | - | - | identical to frame 600, then stack bytes only until ~706 |
| YM #1 / #2 streams | identical to event 63,656 / 109,320 (frame ~673 / ~1,300) | identical to event 99,540 (frame ~2,025) | identical to event 33,961 (frame ~708) |
| Stream timing drift | -1..0 lines | -1..0 lines | -1..0 lines |
| Audio level (AC, window with identical streams) | +0.11 dB, envelope corr 0.93 | -0.30 dB, 0.98 | -0.10 dB, 0.83 |
| DC offset (mean) vs MAME | 3,271 / 3,228 | 4,231 / 4,319 | 5,573 / 5,336 |

Other games after these changes: flytiger and bluehawk M2 boots 0
unexplained, 0 persistent RAM differences; sadari and gundl94 unchanged
(M2, streams, levels); all M1 suites pass (3,875 gate frames, 1,500 extra,
528 synthetic scenes).

The sound streams' later divergences are the R13 class (m3_findings 3):
the jt chips step their timers on their internal sample cycle, MAME's ymfm
counts the exact duration, so a latch command can land either side of a
timer interrupt and the sound program takes its tasks in a different
order. On gulfstrm one block of SSG writes lands 5 ms late, then the
streams are identical again.

Mix gains (sim/m3/fit_opn.py, 20 ms window power over stretches where the
streams are identical): FM 100-102/256 on all three games, i.e. MAME's
0.40 routing (102/256, used). The SSG gain on jt49's 10-bit sum depends on
the chip clock: 4,465/256 at 4 MHz (lastday), 5,500-5,600/256 at 1.5 MHz
(gulfstrm and pollux agree within 2%); dy_snd selects it with the clock.

## 3. jt03 output before the first write

From reset until the sound program's first register writes (0.23 s on
lastday) jt03's FM output sits at a large constant (-49,008 for the pair);
MAME outputs 0. On a real board the output coupling capacitor would remove
it; in the digital mix it would clip and thump at power-on. Each chip's FM
output is held at 0 until its first write.

## 4. Two fixes that apply to every Z80 game

### 4.1 Power-on video phase (was taken for a MAME timestamp artefact)

MAME's screen starts at its vblank line (vpos = visible bottom + 1 = 248)
and raises its first vblank one full frame later. Our counters started at
line 0, so the first IRQ came at line 248, 8 lines early, and every CPU ran
8 lines late against the video from reset. m3_findings 2 had put the
constant 8-line offset in the sound logs down to MAME's timestamps; the
main CPU's early writes (same horizontal position, exactly 8 lines apart)
and the IRQ return addresses on the stack showed it was real. dy_video now
starts at line 248 (0 on the primella family, whose vblank is line 256) and
suppresses the IRQ on that first line. Effect: every sound stream's timing
drift went from 7..8 lines to -1..0, and gulfstrm's streams stay identical
to frame 2,025 instead of 22.

### 4.2 Z80 power-on registers (T80 patch)

MAME's Z80 starts with IX = IY = 0xFFFF; T80's register file starts at 0.
Pollux pushes IY before loading it (a stack slot at 0xCB38 held 0xFFFF in
MAME, 0x0000 in ours from frame 7). T80 now loads IX = IY = 0xFFFF, the
other pairs 0, through its register-file load port during reset
(rtl/vendor/t80/PROVENANCE.md). Work RAM then matches MAME exactly at every
compared vblank up to frame 600.

### 4.3 Mix signedness

The first YM2203 mix expression added an unsigned SSG term to the signed FM
term, so the sum was unsigned and `>>> 8` shifted logically: negative FM
samples became large positive ones (5-12 dB too loud, heavy clipping). The
FM/SSG taps used for the gain fit were taken before the mix, so the fit was
unaffected. With the fix, lastday 10-24 s: AC level -0.05 dB against
MAME, DC 3,232 against 3,169, no clipping, 20 ms envelope correlation 0.93.

## 5. Remaining divergence (research item R15)

pollux's game state (work RAM) splits from MAME's at about frame 706 and
gulfstrm's near frame 8,970; lastday matches for the whole 9,001 frames.
Before the split, only single stack bytes differ now and then from frame 17
on: the low byte of the vblank IRQ's return address (for example 172 in
MAME, 173 in ours), i.e. our CPU sometimes takes the interrupt one
instruction later. T80, like a real Z80, samples INT on the last clock of
an instruction; MAME checks it at the instruction boundary, so an IRQ that
arrives during that last clock is taken one instruction later on our core.
Around frame 706 pollux runs a busy frame where that one instruction decides
whether the main loop finishes before the vblank, and its frame counters
run one frame out of phase from there. The core follows the real CPU here,
so this is recorded rather than changed to copy MAME. The displayed frames
before the split are all exact or line-exact.

Hardware build (2026-09-29): compile 6 failed timing (-0.606 ns, all 400 failing paths inside jt12_pg); jt12_pg multicycle added (Arcade-Dooyong.sdc); compile 7 +0.448 ns / video +3.162 ns / hold +0.253, 20,226 ALMs (48%), 298 RAM blocks (54%). Dooyong_20260929.rbf md5 bb9aaf34 deployed with all 20 MRAs (previous build kept as .bak on the MiSTer).
