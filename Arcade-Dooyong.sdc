derive_pll_clocks
derive_clock_uncertainty

# --------------------------------------------------------------------------
# Multicycle paths inside clock-enabled cores (pattern and rationale from
# the Hyper Duel core). The 96 MHz system clock drives everything, but these
# only advance on enables many clocks apart:
#   T80 main CPU : 8 MHz enable  -> 12 clocks
#   T80 sound CPU: 4 MHz enable  -> 24 clocks
#   jt51         : 3.58 MHz enable -> ~27 clocks
#   jt6295       : 1 MHz enable  -> 96 clocks
# Two cycles is conservative. Only intra-core paths are relaxed; paths into
# and out of the cores (bus decode, RAMs) stay single-cycle. Patterns are
# wildcarded both sides of the instance names.
# --------------------------------------------------------------------------
set_multicycle_path -setup -end 2 \
    -from [get_registers {emu|board|u_sys|u_cpu|*}] -to [get_registers {emu|board|u_sys|u_cpu|*}]
set_multicycle_path -hold -end 1 \
    -from [get_registers {emu|board|u_sys|u_cpu|*}] -to [get_registers {emu|board|u_sys|u_cpu|*}]

set_multicycle_path -setup -end 2 \
    -from [get_registers {emu|board|u_sys|u_snd|u_cpu|*}] -to [get_registers {emu|board|u_sys|u_snd|u_cpu|*}]
set_multicycle_path -hold -end 1 \
    -from [get_registers {emu|board|u_sys|u_snd|u_cpu|*}] -to [get_registers {emu|board|u_sys|u_snd|u_cpu|*}]

set_multicycle_path -setup -end 2 \
    -from [get_registers {emu|board|*u_ym|*}] -to [get_registers {emu|board|*u_ym|*}]
set_multicycle_path -hold -end 1 \
    -from [get_registers {emu|board|*u_ym|*}] -to [get_registers {emu|board|*u_ym|*}]

set_multicycle_path -setup -end 2 \
    -from [get_registers {emu|board|*u_oki|*}] -to [get_registers {emu|board|*u_oki|*}]
set_multicycle_path -hold -end 1 \
    -from [get_registers {emu|board|*u_oki|*}] -to [get_registers {emu|board|*u_oki|*}]

# jt03 (YM2203) phase generator: every register in jt12_pg and its shift
# registers updates only on clk_en = cen & internal divider (4 or 1.5 MHz
# chip enable, at least 24 clocks apart). Only paths with both ends inside
# u_pg are relaxed; the rest of jt12 (register writes at clk speed, the
# registered cen) stays single-cycle. Compile 6: all 400 failing paths
# (worst -0.606 ns) were inside u_pg.
set_multicycle_path -setup -end 2 \
    -from [get_registers {emu|board|*u_opn*|*u_pg|*}] -to [get_registers {emu|board|*u_opn*|*u_pg|*}]
set_multicycle_path -hold -end 1 \
    -from [get_registers {emu|board|*u_opn*|*u_pg|*}] -to [get_registers {emu|board|*u_opn*|*u_pg|*}]

# The game ID is loaded from the MRA while the core is held in reset and
# is static during play.
set_false_path -from [get_registers {emu|board|game*}]
