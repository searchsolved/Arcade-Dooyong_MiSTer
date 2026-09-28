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
