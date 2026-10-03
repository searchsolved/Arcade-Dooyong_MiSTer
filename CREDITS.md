# Credits and third-party components

This core combines new RTL with proven open-source components. Every
third-party component retains its own license and copyright headers in
place; the combined work is distributed under GPL-3.0-or-later (see
LICENSE). Local modifications to vendored cores are documented in each
component's `PROVENANCE.md`.

## New work in this repository

- Dooyong video (`rtl/dy_video.sv`, `rtl/dy_layer_pass.sv`,
  `rtl/dy_spr_z80.sv`): scanline renderer for the ROM tilemaps, text
  layer and both sprite formats. GPL-3.0-or-later.
- System glue for the Z80 and 68000 boards (`rtl/dy_sys.sv`,
  `rtl/dy_snd.sv`, `rtl/dy_pkg.sv`), SDRAM controller (`rtl/dy_sdram.sv`),
  board wrapper (`rtl/dy_board.sv`), MiSTer shell (`Arcade-Dooyong.sv`),
  simulation and verification harness (`sim/`), tooling (`tools/`).
  GPL-3.0-or-later.

## Vendored cores (`rtl/vendor/`)

| Component | Author | License | Upstream |
|---|---|---|---|
| T80 (Z80, main and sound CPU) | Daniel Wallner; MiSTer maintenance by Sorgelig; taken from Jose Tejada's jtframe, whose GHDL translation `T80s.v` is the Verilog used in simulation | BSD-style (see file headers) | https://github.com/jotego/jtcores (modules/jtframe) |
| fx68k (68000, cycle-accurate) | Jorge Cwik | GPL-3.0 | https://github.com/ijor/fx68k |
| jt51 (Yamaha YM2151) | Jose Tejada (@topapate / jotego) | GPL-3.0-or-later | https://github.com/jotego/jt51 |
| jt6295 (OKI MSM6295) | Jose Tejada (@topapate / jotego) | GPL-3.0-or-later | https://github.com/jotego/jt6295 |
| jt03 (Yamaha YM2203, part of jt12) | Jose Tejada (@topapate / jotego) | GPL-3.0-or-later | https://github.com/jotego/jt12 |
| jt49 (the YM2203's SSG, AY-3-8910 compatible) | Jose Tejada (@topapate / jotego) | GPL-3.0-or-later | https://github.com/jotego/jt49 |

Local changes: T80 loads IX = IY = 0xFFFF at reset (MAME's Z80
power-on state; `rtl/vendor/t80/PROVENANCE.md`); fx68k carries the
Verilator portability patches from the Hyper Duel core
(`rtl/vendor/fx68k/PROVENANCE.md`); jt51 has a simulation-only timer
option; jt6295 carries Hyper Duel's Quartus RAM-inference workaround and
simulation-only Verilator annotations, neither changing behaviour, plus two
behaviour fixes that match MAME's M6295 model: a phrase plays through the
second nibble of its stop byte, and a start command to a channel that is
still playing is ignored (`rtl/vendor/SOUND_PROVENANCE.md`). jt03 and jt49
are unmodified; jt51 is unmodified, with its write timing fixed in the
core's sound glue.

Four of the core's sound and CPU blocks come from Jose Tejada's work (jt51,
jt6295, jt03/jt49, and the jtframe packaging of T80). If you enjoy this
core, consider supporting him: https://www.patreon.com/jotego

## MiSTer framework (`sys/`)

The MiSTer template and framework files are copyright their respective
authors (Sorgelig and MiSTer-devel contributors), GPL-2.0-or-later.
https://github.com/MiSTer-devel

## Reference material

- MAME's `dooyong.cpp` and `dooyong_tilemap.cpp/.h` (BSD-3-Clause,
  copyright Nicola Salmoria, Vas Crabb and contributors) are vendored
  under `reference/mame/` as the behavioural documentation of record.
  This core would not exist without that reverse-engineering work.
  https://github.com/mamedev/mame

## The games

The games are copyright Dooyong and their licensees (NTC, Mitchell,
Media Shoji, Atlus). This repository contains no game ROM data in any
form; the core loads a user-supplied MAME ROM set at runtime via the
MRA files.
