# T80 (Z80 core)

Source: jotego/jtcores, `modules/jtframe/hdl/cpu/t80/`, commit
0b197caeae1596380863b8388552b125e7e1b208 (fetched 2026-09-28 through the
GitHub API). Files unchanged.

- `T80*.vhd`: Daniel Wallner's T80 (BSD-style licence in each file header),
  as maintained in jtframe. Used for synthesis (Quartus).
- `T80s.v`: jtframe's GHDL translation of `T80s` (Mode 0, T2Write 1,
  IOWait 1) to Verilog, used for Verilator simulation, the same way
  jtframe's `jtframe_z80.v` does. Same logic as the VHDL, so simulation and
  hardware run one CPU implementation.

## Local patch (2026-09-29)

MAME's Z80 powers up with IX = IY = 0xFFFF (BC, DE, HL and the alternates
0); T80's register file starts at 0 and has no reset. Pollux pushes IY
before ever loading it, so the pushed value (a stack slot at 0xCB38) and,
later, the attract demo diverged from MAME (docs/ym2203_findings.md). The
register file's existing load port (DIRSet/DIR, used by jtframe for save
states) is now also driven during reset with IX = IY = 0xFFFF and the other
pairs 0:
- `T80.vhd`: signals RegDIRSet / RegDIR feeding the T80_Reg instance.
- `T80s.v`: the same at the `u_regs` instance (`.dirset`, `.dir`).
Nothing else changed.
