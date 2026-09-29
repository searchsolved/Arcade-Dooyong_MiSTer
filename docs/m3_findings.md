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
| `rtl/vendor/jt51`, `rtl/vendor/jt6295` | from Hyper Duel (proven on hardware), see `SOUND_PROVENANCE.md` |
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
