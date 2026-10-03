# M3 findings: sound (YM2151 + M6295 games)

Date: 2026-09-28. Scope: flytiger and bluehawk sound systems: sound Z80
(T80) with the sound ROM in BRAM, 2 KB RAM, the latch, jt51 (YM2151) and
jt6295 (M6295), in `rtl/dy_snd.sv`, inside `dy_sys`. Reproduce: `cd sim &&
make m3-wav m3` (7,300 frames = 121.7 s of each game from power-on, about
an hour with both games in parallel).

## 1. Gate

| Gate item | Result | Evidence |
|---|---|---|
| Mix level within 1 dB of MAME | PASS | flytiger +0.17 dB, bluehawk +0.29 dB over 121.7 s against MAME's WAV of the same run; 5 s segments: flytiger -0.26 to +0.50 dB, bluehawk -0.39 to +2.65 dB (the larger ones after its streams diverge, when different sounds play); 20 ms envelope correlation 0.988 / 0.90 |
| Register-stream parity for 2 minutes | PARTIAL | identical in order and value for 47 s on flytiger (YM2151 writes to frame 6,224 = 104 s, M6295 commands to frame 2,810) and 35 s on bluehawk (M6295 to frame 2,125, YM2151 to frame 3,224); after that the sound programs take different decisions (section 3) |
| Sound-ROM writes (spec T4) | PASS | order and values identical to MAME over the whole run: flytiger 73,266 of 73,266, bluehawk 98,050 against MAME's 98,054 (the 4 fall at the window edge) |

## 2. What was checked and matches MAME

- Sound CPU timing: T80's cycle count per instruction equals the documented
  Z80 timing for every opcode in the boot path, and MAME's sound CPU
  follows the same counts (its delay-loop registers sampled at 1/60 s put
  it at cycle 66,666 of 66,667). Both CPUs execute the same instruction
  sequence from reset to the first timer interrupt.
- MAME's logged beam positions for sound-CPU writes sit a constant 8 lines
  before ours, although both CPUs reach the write at the same cycle count
  from reset. The offset is in MAME's timestamps for the sound CPU, not in
  the core; `compare_snd.py` reports it as drift and allows 32 lines.
  **Corrected 2026-09-29 (ym2203_findings 4.1):** the offset was real. MAME's
  screen starts at the vblank line with its first vblank one frame later;
  our video counters started 8 lines further on. Fixed in dy_video; the
  drift is now -1..0 lines.
- YM2151 timer A period: 20,883 CPU cycles measured against 20,883.1 in
  theory (NA = 732 at 3.579545 MHz).
- M6295 status: MAME's status polled at each frame end from frame 320 to
  360 equals our channel busy bits on all 41 frames.
- Mix gains: MAME routes YM left and right at 0.35 and the M6295 at 0.42
  into one speaker; the core uses the same gains, with the M6295's 12-bit
  channel sum converted at MAME's 1/2048 of full scale.

## 3. Where the streams diverge

The sound programs poll the latch and the chip status from a YM timer
interrupt, and some of their decisions (for example whether to stop a
channel before starting a sample) depend on timing at the sub-millisecond
level. Two differences affect that timing:

1. Timer phase. jt51 steps its timers on its internal 64-clock sample
   cycle, so the first overflow after a load comes up to 64 YM clocks after
   the exact duration; MAME's ymfm counts the exact duration from the write.
   A real YM2151 is also clocked by its internal cycle, so jt51 is plausibly
   the closer of the two. A simulation-only MAME-style timer
   (`JT51_TIMER_EXACT`) moves the divergence points (bluehawk M6295 from
   frame 2,125 to 1,269; flytiger YM2151 identical through at least frame
   5,180) but does not remove them, so it is not the only cause.
2. Something not identified. With the MAME-style timer the flytiger M6295
   stream still diverges at frame 2,810 (a different sample chosen about a
   frame later). At one bluehawk status read MAME returns a channel as idle
   in the middle of a stop-and-restart sequence where the frame-end poll and
   our core both show it busy; the ordering inside one MAME scheduler slice
   decides that value.

Finding the remaining cause would need cycle-level co-simulation against
MAME's scheduler. MAME is not the ground truth here either (its scheduler
interleaves the two CPUs and the chips in time slices). The audible result
matches on level and envelope; which sample plays in a few overlapping
sound effects can differ. Open item R13 below; the core ships jt51's own
timers.

## 4. Built

| File | Content |
|---|---|
| `rtl/dy_snd.sv` | sound Z80 at 4 MHz, 64 KB ROM (BRAM, download port), 2 KB RAM, latch, jt51 at 3.579545 MHz (fractional enable, cen_p1 every other enable), jt6295 at 1 MHz pin 7 high, IRQ from the YM2151, mono mix with clamp |
| `rtl/vendor/jt51`, `rtl/vendor/jt6295` | from Hyper Duel (proven on hardware), see `rtl/vendor/SOUND_PROVENANCE.md` |
| `sim/m2/tb_sys.cpp` | now downloads the sound ROM, models the M6295 ROM port with latency, logs sound writes (`+snd`), OKI status reads and channel state, writes the mix at 48 kHz (`+wav`), and can trace sound-CPU opcode fetches with cycle counts (`+cputrace`) |
| `sim/m3/compare_snd.py` | register-stream comparison with MAME's write log |
| `sim/m3/compare_audio.py` | level and envelope comparison with MAME's WAV |

Simulation cost: 0.49 s per frame with sound (0.23 s without).

## 5. Open items

- R13: sound-program divergence from MAME after 35-47 s (section 3). Settle
  on hardware by ear first; if a difference is audible, compare with a PCB
  recording.
- lastday, gulfstrm, pollux: 2x YM2203 (jt03) sound and their main-system
  decode, per PLAN section 3.
- The OKI sample ROM is read through the harness model; on hardware it
  comes from SDRAM (M4).

## 6. Sound fixes from the 1945k III and Tecmo 16 cores (2026-10-03)

Two jt6295 patches (from the 1945k III core) and one change to the YM2151
write path (from the Tecmo 16 core); details and evidence in
`rtl/vendor/SOUND_PROVENANCE.md`, research item R17:

1. jt6295 phrase end: a phrase now plays through the second nibble of its
   stop byte, 2 x (stop - start + 1) samples, as MAME's okim6295 does.
   Before, busy cleared one sample (about 132 us) early.
2. jt6295 start to a busy channel: ignored, as MAME (okim6295.cpp
   L281-284) and jt6295's own README describe. Before, it restarted the
   phrase.
3. YM2151 writes (`rtl/dy_snd.sv`): held until the next `cen_p1`, because
   jt51 sets its busy flag only for a write on a `cen_p1` clock and the
   one-clock chip select hit it about once in 50 writes.

Believed accurate: the patched behaviour in all three (MAME's model, the
phrase table format, jt6295's documented intent and jt51's busy logic
agree; the OKI datasheet was not checked, R17).

### 6.1 Verification

Every YM2151/M6295 game booted from power-on in the dy_sys harness, built
from the same tree in three variants: base (HEAD jt6295 and dy_snd), patch
(jt6295 patches 1 and 2 only) and final (patches 1 and 2 plus the YM2151
write hold), with captures, the sound register log and the 48 kHz mix, at
the MRA DIP defaults (sadari/gundl94 DSWB FD, popbingo DSWA FB). Runs
stopped at frames 2,800 to 3,500 (47 to 58 s), past every known divergence
point; the shared machine ran them at about 750 frames an hour. Outputs:
`sim/build/m2/oki_base`, `oki_patch`, `oki_fix2` (final), comparison log
`sim/build/m2/oki_compare.txt`. The YM2203 games (lastday, gulfstrm,
pollux) have no M6295 and use jt03, which needed no change; they were not
re-run.

| Game | Streams vs MAME (base, patch and final identical) | First difference from base | Level vs MAME: base / final |
|---|---|---|---|
| flytiger | YM2151 21,510, M6295 408 and sound ROM 40,910 events identical to frame 2,950 | busy bits at vblank 2,285 (patch 1: a phrase ends one sample later) | +0.16 / +0.11 dB |
| bluehawk | YM2151 identical; M6295 first mismatch at frame 2,125 (R13, section 3) | busy bits at vblank 689 (patch 1) | +0.19 / +0.24 dB |
| sadari | YM2151 20,159 and M6295 76 identical to frame 2,950 | none | +0.23 / +0.43 dB |
| gundl94 | YM2151 20,159 and M6295 113 identical to frame 2,950 | none | +0.27 / +0.47 dB |
| superx | first mismatch M6295 frame 684, YM2151 frame 776 (R16, m68k_findings 4) | status read at frame 1,233 (0xF9 vs 0xF8, patch 1), program flow follows | +0.03 / +0.02 dB |
| rshark | first mismatch frame 1,481 (R16) | none | +0.50 / +0.44 dB |
| popbingo | YM2151 29,976 and M6295 39,227 identical to frame 2,800 | busy bits at vblank 2,428 (patch 1) | +0.49 / +0.36 dB |

The levels are over each run's common window with MAME's WAV (47 to 58 s),
so base and final columns cover slightly different lengths; base and patch
over the same window differed by 0.02 dB at most.

Results:
- Program flow and sound streams match MAME as far as before: the first
  MAME mismatch is the same event in all three variants on every game, and
  every one is a divergence documented before (R13, R16). The jt6295
  patches' own effects appear later (third column), so within the
  MAME-comparable window they neither improve nor worsen parity.
- The YM2151 write hold changed nothing in any logged stream: the final
  and patch logs are identical. In MAME the Dooyong sound drivers read the
  YM2151 status 10,814 (bluehawk) to 45,306 (superx) times per 1,200 frames
  and see busy set 0 times (read tap, `sim/build/ym_rd_tap.lua`): their
  writes are spaced wider than the busy time, so the flag never decides
  anything on these games. The fix stays for accuracy (the chip's busy flag
  now behaves) at no cost to parity.
- Loudness: none of these games re-sends start commands to a playing
  channel the way 1945k III and Solite Spirits do every frame (those were
  up to 15 dB too loud before patch 2), so the Dooyong mix is practically
  unchanged; every game stays within 0.5 dB of MAME.
- flytiger's streams now match MAME to frame 2,950 at least, past the
  2,810 of section 1. That predates these patches (base matches too): it
  came with the 2026-09-29 power-on timing fixes (ym2203_findings).

### 6.2 R13 status

Unchanged by these fixes. bluehawk still leaves MAME's path at frame 2,125
(M6295 event 1,455: the driver stops channel 1 before restarting it where
MAME restarts it directly), with all three variants. The YM2151 busy flag
is ruled out as a cause (6.1), as the YM timer period and M6295 status were
before (section 3). Still open; settle by ear on hardware first.

### 6.3 Not taken: the Tecmo 16 core's jt6295 busy patch

The Tecmo 16 core also updates jt6295's busy flags only at `cen4`, from the
committed channel state, to stop a start command's first byte from
cancelling a stop that is not yet committed (Ganbare Ginkun's stepped
fade-outs). Built and run here with the other patches, it moved bluehawk's
first MAME mismatch from frame 2,125 to 1,269: at frame 331 the driver
stops channel 1 and reads the status straight away; the patched chip still
showed channel 1 busy (0xF3), the unpatched one idle (0xF2), and later
decisions followed that read. MAME clears a voice at the stop write
(okim6295.cpp write(), silence command), so the status shows idle at once:
the patch moves jt6295 away from MAME on this pattern. Runs kept in
`sim/build/m2/oki_fix3_rejected`. A fix faithful to MAME on both games
needs a stop visible to status at once and a start's first byte that does
not clear pending stops in `jt6295_ctrl.v`; not done here (R17).

### 6.4 Build

Compile on 2026-10-03 15:23 (Quartus 17.0 Lite, E-core task `dycompile`):
every clock non-negative (96 MHz core setup +0.894 ns, hold +0.243 ns;
video setup +3.530 ns), 22,767 ALMs (54%), 497 of 553 RAM blocks (90%), 46
DSP. RBF md5 `211c23913a474de03e9d4e9356ef3c4a`. An earlier attempt that
morning did not run: the PC crashed a minute after Quartus started
(Kernel-Power 41), the known instability; a compile at 11:32 with the
jt6295 patches only (no YM2151 change) also met timing (+0.472 ns) and was
superseded.
