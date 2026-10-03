# jt51 and jt6295

Copied on 2026-09-28 from the Hyper Duel MiSTer core
(`hyperduel-mister/rtl/vendor/`, repository commit
e2f18f5a966213734d3f346f91e908eff52fde7d), where both are proven on
hardware. Upstream: jotego/jt51 and jotego/jt6295 (GPL-3.0, see each
LICENSE). Only `hdl/`, `LICENSE` and `README.md` were copied.

Carried-over patch (from Hyper Duel's `rtl/vendor/PATCHES.md`):
- `jt6295/hdl/jt6295_adpcm.v`: `(* ramstyle = "logic" *)` on `lut` and
  `gain_lut`, avoiding a Quartus 17.0 RAM-inference crash on these tiny
  tables. No functional change; Verilator ignores it.

Dooyong edits (simulation only, no effect on synthesis):
- `jt51/hdl/jt51_timers.v`: an `ifdef JT51_TIMER_EXACT` block (off by
  default) that counts the timers from the load write in phiM clocks, as
  MAME's ymfm does, instead of on jt51's internal sample-cycle tick. Used
  for the M3 investigation in `docs/m3_findings.md`; the core uses jt51's
  own timers.
- `jt6295/hdl/jt6295.v`: `verilator public_flat_rd` comments on the
  `busy`, `start` and `stop` wires so the harness can log channel state.

Dooyong behaviour patches to jt6295 (2026-10-03, ported from the 1945k III
core, `1945kiii-mister/rtl/vendor/jt6295/PROVENANCE.md`; both change the
synthesised chip; verification in `docs/m3_findings.md` section 6):
- `jt6295/hdl/jt6295_serial.v`, patch 1, phrase end: the original
  `assign over = rom_addr >= stop_out;` ends a voice after the first nibble
  of the stop byte, 2 x (stop - start) + 1 samples. The MSM6295 phrase table
  gives the last byte of the phrase as the stop address, and MAME's
  okim6295 plays 2 x (stop - start + 1) samples. Patched to
  `assign over = cnt >= {stop_out, 1'b1};`. Measured in the 1945k III core:
  busy cleared 137 one-MHz enables early before, 5 (start latency) after.
- `jt6295/hdl/jt6295_serial.v`, patch 2, start on a busy channel: the
  original reloads a channel on every start request, so a start to a
  playing channel restarts its phrase. Patched with
  `start_ok = up_start & ~busy_out` in the reload terms, so such a start is
  ignored; the request is still acknowledged so jt6295_ctrl clears it, and a
  stop on the same cycle still wins. Evidence: MAME 0.288 okim6295.cpp
  L281-284 ignores the start ("Requested to play sample %02x on non-stopped
  voice"); jt6295's own README (lines 31-33) describes this behaviour, which
  its code did not implement (upstream master the same, checked
  2026-10-03). The OKI datasheet was not checked; believed accurate:
  ignore. Upstream: jotego/jt6295 has neither patch.

Not taken: the Tecmo 16 core's third patch (busy flags updated on `cen4`,
the committed channel state). It fixes a real upstream fault (a start
command's first byte clears every pending stop in `jt6295_ctrl.v`, so a stop
not yet committed can be cancelled), but it does so by keeping a stopped
channel reading busy until its slot commits. MAME clears a voice's playing
flag at the stop write (okim6295.cpp, write(): silence command), so a status
read straight after a stop shows it idle. Blue Hawk's sound driver does
exactly that (stop channel 1, read status, frame 331): with the patch the
read returned 0xF3 where upstream (and MAME's later program flow) gives
0xF2, and the sound program left MAME's path at frame 1,269 instead of
2,125. A MAME-faithful fix needs the stop visible at once and the start's
first byte not clearing pending stops (m3_findings 6.3, R17).

jt51 (YM2151) is unchanged; its write timing is fixed in `rtl/dy_snd.sv`
(2026-10-03, from the Tecmo 16 core's `t16_snd.sv`): jt51 sets its busy
flag only for a write that coincides with `cen_p1` (`jt51_mmr.v`, busy
updates under `cen`), and the one-clock chip select hit it about once in 50
writes. Writes are now held until the next `cen_p1`, so status reads see
busy after a data write as on the chip. jt03 (YM2203) sets busy on any
write and needed no change.

Patch 3 (2026-10-03, R17, `jt6295_ctrl.v`, `jt6295_serial.v`,
`jt6295.v`): the status read (BUSY) is timed as the MSM6295 datasheet
(p. 73: "BUSY becomes "H" after 15 x n clock" from a start's second
byte; after a stop, "voice playback stops all the next sample and BUSY
becomes "L""); whether a start is accepted follows MAME's per-voice
"playing" flag, since the datasheet does not cover a start to a playing
channel or a restart within one sample of a stop; a start's first byte no
longer clears pending stops; a stop cancels a queued start for its
channel; the ADPCM decoder resets on every start. This replaces the Tecmo 16 core's earlier patch
3 that this core did not take (above). The datasheet (MSM6295, later
edition, p. 73) was read by two people and outranks MAME here; MAME
decides what it leaves open. Verification: docs/m3_findings.md 6.5. The patched files are identical in four cores (1945k III, Tecmo 16,
Dooyong, Hyper Duel): hdl/jt6295.v md5 5ac531e429298723ae48a064551b9685,
hdl/jt6295_ctrl.v 3c275bd9d77dc5dbc89eea5d4a277aa5, hdl/jt6295_serial.v
5523e7c4708b29324ed409d16cad92a2. Full description, datasheet quotes and
per-game results: `1945kiii-mister/rtl/vendor/jt6295/PROVENANCE.md`
(patch 3).
