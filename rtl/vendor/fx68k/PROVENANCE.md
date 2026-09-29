# fx68k (68000, cycle-accurate)

Jorge Cwik, https://github.com/ijor/fx68k, GPL-3.0 (LICENSE). Copied
2026-09-29 from the Hyper Duel core (hyperduel-mister/rtl/vendor/fx68k,
cloned from GitHub 2026-07-04, running on the MiSTer in that core), with
its patches (hyperduel-mister/rtl/vendor/PATCHES.md):
- fx68k.sv: the three structs packed under `ifdef VERILATOR` only
  (Verilator BLKANDNBLK); Quartus sees the original.
- fx68k.sv, fx68kAlu.sv: `unique case` -> `case` (Verilator run-time
  check at time 0).
- fx68kAlu.sv: ccrTable `default: ccrMask = CUNUSED;` restored (Quartus
  17.0 latch inference after the previous change; unreachable branch).
No functional change. microrom.mem and nanorom.mem are the core's
microcode and nanocode ROMs.

Used by the 68000 games (superx, rshark, popbingo) as the main CPU.
