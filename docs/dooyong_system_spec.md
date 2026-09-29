# Dooyong ROM-Tilemap Hardware - System-Level Specification

Source: MAME `src/mame/dooyong/dooyong.cpp`, `dooyong_tilemap.cpp`,
`dooyong_tilemap.h` (BSD-3-Clause, Nicola Salmoria, Vas Crabb), master
commit 2969c05d (2026-09-27), vendored in `reference/mame/`. Every fact
below cites a line in that copy. Citations of the form `123` or `123-130`
are lines in `dooyong.cpp`; `tm.cpp:N` and `tm.h:N` are lines in
`dooyong_tilemap.cpp` / `dooyong_tilemap.h`. MAME core behaviour that the
driver relies on (priority bitmap rules, region byte order, palette
formats) was read from the same MAME commit and is cited by file.

Status: written 2026-09-27 from source only; updated the same day with
the M0 results (ROM checks, MAME 0.288 oracle runs, `docs/m0_findings.md`).
Sections 5.4, 6.3, 7.2, 7.3, 11.10 and 14 carry the M0 answers; the Python
reference renderer (`sim/oracle/dy_render.py`) implements sections 6-12
for the Z80 family and matches MAME pixel for pixel on every captured frame.
Anything marked **TODO(MAME)** is an uncertainty MAME itself admits.
Anything marked **OPEN** is a question raised while writing this spec.
Both lists are collected in section 14 and carried into `PLAN.md`.

## 1. Family overview

The driver header lists ten games on "different but similar hardware",
all sharing tilemaps stored in ROM (9-21).

| Parent | Year | Main CPU | Sound CPU | Sound chips | Rot | Machine config | GAME line |
|---|---|---|---|---|---|---|---|
| lastday | 1990 | Z80 | Z80 | 2x YM2203 | ROT270 | `lastday` 1498-1531 | 2833 |
| gulfstrm | 1991 | Z80 | Z80 | 2x YM2203 | ROT270 | `gulfstrm` 1533-1566 | 2837 |
| pollux | 1991 | Z80 | Z80 | 2x YM2203 | ROT270 | `pollux` 1568-1601 | 2843 |
| flytiger | 1992 | Z80 | Z80 | YM2151 + M6295 | ROT270 | `flytiger` 1647-1681 | 2848 |
| bluehawk | 1993 | Z80 | Z80 | YM2151 + M6295 | ROT270 | `bluehawk` 1603-1645 | 2851 |
| sadari | 1993 | Z80 | Z80 | YM2151 + M6295 | ROT0 | `primella` 1683-1717 | 2855 |
| gundl94 | 1994 | Z80 | Z80 | YM2151 + M6295 | ROT0 | `primella` 1683-1717 | 2857 |
| superx | 1994 | 68000 | Z80 | YM2151 + M6295 | ROT270 | `superx` 1782-1787 | 2860 |
| rshark | 1995 | 68000 | Z80 | YM2151 + M6295 | ROT270 | `rshark` 1775-1780 | 2863 |
| popbingo | 1996 | 68000 | Z80 | YM2151 + M6295 | ROT0 | `popbingo` 1789-1822 | 2866 |

Clones (2833-2866): lastdaya, ddaydoo (lastday); gulfstrma, gulfstrmb,
gulfstrmm, gulfstrmk (gulfstrm); polluxa, polluxa2, polluxn (pollux);
flytigera; bluehawkn, bluehawkna; primella (gundl94); superxm; rsharka.
25 sets in total, all flagged `MACHINE_SUPPORTS_SAVE` with no imperfect
flags.

Class structure: `dooyong_z80_state` (121-257) covers all Z80 games;
`dooyong_z80_ym2203_state` (259-313) adds the YM2203 games;
`dooyong_68k_state` (316-342) is the base for `rshark_state` (345-377,
used by superx and rshark) and `popbingo_state` (380-417).

Note: `src/mame/dooyong/gundealr.cpp` (Gun Dealer 1990, Wiseguy, Yam! Yam!?)
is a separate, different Dooyong board and is out of scope.

## 2. Clocks

| Game | Main CPU | Sound CPU | FM | OKI | Source / MAME comment |
|---|---|---|---|---|---|
| lastday | Z80 8 MHz (16/2) | Z80 4 MHz (16/4) | 2x YM2203 4 MHz (16/4) | - | 1501, 1505, 1530, all "verified for Last Day / D-day" |
| gulfstrm | Z80 8 MHz | Z80 8 MHz | 2x YM2203 1.5 MHz | - | 1536 "???", 1540 "???", 1565 value 1,500,000 with comment "3.579545MHz" |
| pollux | Z80 8 MHz (16/2) | Z80 4 MHz (16/4) | 2x YM2203 1.5 MHz | - | 1571, 1575, 1600 "1.5MHz verified" |
| bluehawk | Z80 8 MHz | Z80 4 MHz | YM2151 3.579545 MHz | 1 MHz, pin 7 high | 1606 "???", 1610 "???", 1644 "3.579545MHz or 4Mhz ???" |
| flytiger | Z80 8 MHz (16/2) | Z80 4 MHz (16/4) | YM2151 3.579545 MHz XTAL | 1 MHz XTAL, pin 7 high | 1650, 1654, 1680; PCB notes 2359-2367 agree |
| sadari, gundl94, primella | Z80 8 MHz (16/2) | Z80 4 MHz (16/4) | YM2151 4 MHz (16/4) | 1 MHz (16/16), pin 7 high | 1686, 1690, 1716 "PCB has only 1 OSC at 16Mhz" |
| superx, rshark | 68000 8 MHz | Z80 4 MHz (8/2) | YM2151 4 MHz (8/2) | 1 MHz (8/8), pin 7 high | 1735 "8MHz measured on Super-X", 1738, 1772; PCB notes 2571-2577 |
| popbingo | 68000 10 MHz (20/2) | Z80 4 MHz (16/4) | YM2151 4 MHz (16/4) | 1 MHz (16/16), pin 7 high | 1792 "10MHz measured", 1796, 1821; PCB notes 2791-2797 |

OKI pin 7 high means a sample-rate divisor of 132 (okim6295.cpp, MAME
core: `m_pin7_state ? 132 : 165`), 1 MHz / 132 = 7575.76 Hz. The PCB
notes for flytiger (2364), superx (2575) and popbingo (2795) state
"Sample Rate = 1000000 / 132", which matches.

**TODO(MAME):** the 8 MHz sound CPU is a deliberate hack "to avoid jerky
music when there's (too) many SFX scheduled" (58-60). In the current
driver it only applies to gulfstrm (1540); lastday and pollux run the
sound Z80 at 4 MHz.

**OPEN:** gulfstrm's YM2203 value (1.5 MHz) contradicts its own comment
(3.579545 MHz) (1565). Pollux's 1.5 MHz is marked verified (1600) but is
not an integer division of the 16 MHz crystal the other clocks come
from; it suggests a second oscillator or a non-obvious divider. Bluehawk's
four clocks are all unverified (1606, 1610, 1644).

## 3. Main CPU memory maps

Default MAME unmapped read value is 0 (addrmap.cpp, `m_unmapval(0)`).
"Write-only" below means MAME maps only a write handler plus a memory
share; CPU reads of that range return the unmapped value.

### 3.1 Z80 bank switching (all Z80 games)

`mainbank` has 8 entries of 0x4000 bytes starting at the base of the
`maincpu` region (212), mapped at 0x8000-0xBFFF in every Z80 map.
`bankswitch_w` selects `data & 7` and pops a debug message if any of
bits 3-7 are set (150-154). Every Z80 `maincpu` region is 0x20000 bytes
(section 13), so bank 0 aliases the fixed 0x0000-0x3FFF and banks 4-7
read zero-fill on pollux, whose program ROM is only 0x10000 bytes
(2122-2123). Primella-family games bank through `primella_ctrl_w`
bits 0-2 instead (466-467).

### 3.2 lastday (802-820)

| Range | R | W |
|---|---|---|
| 0x0000-0x7FFF | program ROM | - |
| 0x8000-0xBFFF | bank (3.1) | - |
| 0xC000-0xC007 | - | bg0 tilemap regs (806) |
| 0xC008-0xC00F | - | fg0 tilemap regs (807) |
| 0xC010 | SYSTEM | `lastday_ctrl_w` (808-809) |
| 0xC011 | P1 | `bankswitch_w` (810-811) |
| 0xC012 | P2 | sound latch (812-813) |
| 0xC013 | DSWA | - (814) |
| 0xC014 | DSWB | - (815) |
| 0xC800-0xCFFF | palette RAM | palette RAM (816) |
| 0xD000-0xDFFF | text RAM, lane split (817, 156-166) | same |
| 0xE000-0xEFFF | work RAM (818) | same |
| 0xF000-0xFFFF | sprite RAM (819) | same |

### 3.3 gulfstrm (841-858) and pollux (822-839)

Corrected 2026-09-29 from the driver (the first version of this table
listed bluehawk's I/O addresses).

| Range | R | W |
|---|---|---|
| 0x0000-0x7FFF | program ROM | - |
| 0x8000-0xBFFF | bank | - |
| 0xC000-0xCFFF | work RAM | same |
| 0xD000-0xDFFF | sprite RAM | same |
| 0xE000-0xEFFF | text RAM, lane split (156-166) | same |
| 0xF000 | DSWA | `bankswitch_w` |
| 0xF001 | DSWB | - |
| 0xF002 | P1 (pollux), **P2 (gulfstrm)** | - |
| 0xF003 | P2 (pollux), **P1 (gulfstrm)** | - |
| 0xF004 | SYSTEM | - |
| 0xF008 | - | `pollux_ctrl_w` |
| 0xF010 | - | sound latch |
| 0xF018-0xF01F | - | bg0 tilemap regs |
| 0xF020-0xF027 | - | fg0 tilemap regs |
| 0xF800-0xFFFF | palette RAM (pollux: banked, 180-192) | same |

### 3.4 bluehawk (860-879)

| Range | R | W |
|---|---|---|
| 0xC000 | DSWA | `flip_screen_w` |
| 0xC001 | DSWB | - |
| 0xC002 | P1 | - |
| 0xC003 | P2 | - |
| 0xC004 | SYSTEM | - |
| 0xC008 | - | `bankswitch_w` |
| 0xC010 | - | sound latch |
| 0xC018-0xC01F | - | fg1 tilemap regs |
| 0xC040-0xC047 | - | bg0 tilemap regs |
| 0xC048-0xC04F | - | fg0 tilemap regs |
| 0xC800-0xCFFF | palette RAM | same |
| 0xD000-0xDFFF | text RAM, byte interleaved (168-178) | same |
| 0xE000-0xEFFF | sprite RAM | same |
| 0xF000-0xFFFF | work RAM | same |

`flip_screen_w` passes the whole byte to `flip_screen_set`, so any
non-zero value flips.

### 3.5 flytiger (881-899)

| Range | R | W |
|---|---|---|
| 0x0000-0x7FFF | program ROM | - |
| 0x8000-0xBFFF | bank | - |
| 0xC000-0xCFFF | sprite RAM | same |
| 0xD000-0xDFFF | work RAM | same |
| 0xE000 | P1 | `bankswitch_w` |
| 0xE002 | P2 | - |
| 0xE004 | SYSTEM | - |
| 0xE006 | DSWA | - |
| 0xE008 | DSWB | - |
| 0xE010 | - | `flytiger_ctrl_w` |
| 0xE020 | - | sound latch |
| 0xE030-0xE037 | - | bg0 tilemap regs |
| 0xE040-0xE047 | - | fg0 tilemap regs |
| 0xE800-0xEFFF | banked palette (180-192) | same |
| 0xF000-0xFFFF | text RAM, lane split | same |

Odd addresses in 0xE001-0xE00F are unmapped.

### 3.6 sadari / gundl94 / primella (901-918)

| Range | R | W |
|---|---|---|
| 0x0000-0x7FFF | program ROM | - |
| 0x8000-0xBFFF | bank (via ctrl bits 0-2) | - |
| 0xC000-0xCFFF | work RAM | same |
| 0xD000-0xD3FF | RAM, "what is this? looks like a palette? scratchpad RAM maybe?" (906) | same |
| 0xE000-0xEFFF | text RAM, byte interleaved | same |
| 0xF000-0xF7FF | unmapped (write-only palette) | palette (908) |
| 0xF800 | DSWA | `primella_ctrl_w` |
| 0xF810 | DSWB | sound latch |
| 0xF820 | P1 | - |
| 0xF830 | P2 | - |
| 0xF840 | SYSTEM | - |
| 0xFC00-0xFC07 | - | bg0 tilemap regs |
| 0xFC08-0xFC0F | - | fg0 tilemap regs |

No sprite RAM and no sprite ROM on this hardware (2466, 2494, 2526).

### 3.7 68000 games

All three use `global_mask(0xfffff)` (922, 941, 960), so the 68000 sees
a 1 MB space mirrored across 16 MB. Byte-wide peripherals sit on the low
byte lane (odd addresses, or `umask16(0x00ff)` for the tilemap regs).

| Function | rshark (920-937) | superx (939-956) | popbingo (958-977) |
|---|---|---|---|
| Program ROM (256 KB) | 0x000000-0x03FFFF | same | same |
| Work RAM | 0x040000-0x04CFFF, 0x04E000-0x04FFFF | 0x0D0000-0x0DCFFF, 0x0DE000-0x0DFFFF | as rshark |
| Sprite RAM (4 KB) | 0x04D000-0x04DFFF | 0x0DD000-0x0DDFFF | as rshark |
| DSW (16-bit read) | 0x0C0002 | 0x080002 | 0x0C0002 |
| P1_P2 (16-bit read) | 0x0C0004 | 0x080004 | 0x0C0004 |
| SYSTEM (read) | 0x0C0006 | 0x080006 | 0x0C0006 |
| Sound latch (byte write) | 0x0C0013 | 0x080013 | 0x0C0013 |
| `ctrl_w` (byte write) | 0x0C0015 | 0x080015 | 0x0C0015 |
| bg0 regs | 0x0C4000-0x0C400F lo byte | 0x084000-0x08400F | 0x0C4000-0x0C400F |
| bg1 regs | 0x0C4010-0x0C401F | 0x084010-0x08401F | 0x0C4010-0x0C401F |
| Palette (write-only, 4 KB) | 0x0C8000-0x0C8FFF | 0x088000-0x088FFF | 0x0C8000-0x0C8FFF |
| fg0 regs | 0x0CC000-0x0CC00F | 0x08C000-0x08C00F | not present (974) |
| fg1 regs | 0x0CC010-0x0CC01F | 0x08C010-0x08C01F | not present (975) |
| Other | writes to 0x0C0018/0x0C001A unmapped | writes to 0x080018/0x08001A unmapped | 0x0C0018-0x0C001B write no-op (970); 0x0DC000-0x0DC01F RAM "registers of some kind?" (976) |

With `umask16(0x00ff)`, 16 bytes of 68000 address map onto 8 register
offsets, so tilemap register N is at base + 2N + 1.

**TODO(MAME):** rshark and superx "regularly" write 0x0000 to +0x18 and
+0x1A of their I/O block: watchdog, peripheral or bug is unknown (30-34).
Pop Bingo has "some unknown reads / writes" (42-43).

### 3.8 Unexplained writes to ROM (all TODO(MAME))

- bluehawk and flytiger main programs write a fixed sequence to
  0x0000-0x001F (26-29).
- bluehawk, flytiger, superx, rshark and popbingo sound programs write
  0x00 to 0x0003 and 0xF7 to 0x0004 (35-38). "Possibly a watchdog?"

MAME ignores all of these. The core should ignore them too, and log them
in simulation so the patterns can be compared with PCB evidence.

M0 logs (12,000 attract frames per parent, `docs/m0_findings.md` section 5):
flytiger writes 0x00 to 0x0000 and then the ROM's own bytes 0x0000-0x001E
(`F3 ED 56 C3 3E 00 FF ...`) to 0x0001-0x001F, then 0x02 to 0x001C and 0xF0
to 0x0002, about 95 times per 12,000 frames. That is the Z80 block-fill idiom
(`LD (HL),0` then `LDIR` from HL to HL+1) run on a zero base pointer
followed by field stores, i.e. a program clearing and initialising a
32-byte object at address 0: a software null-pointer pattern, not a
peripheral. bluehawk only wrote 0xFE to 0x0018 twice. The sound programs
write 0x00 to 0x0003 and 0xF7 to 0x0004 about three times per frame each
(same pattern in all five YM2151 games), plus a few bytes at 0x0006,
0x0012 and 0x0013 once at boot. rshark, superx and popbingo write 0x0000
to +0x18 and +0x1A once per frame.

## 4. Sound CPU memory maps

| Range | lastday + gulfstrm (979-986) | pollux (988-995) | all YM2151 games (997-1004) |
|---|---|---|---|
| ROM | 0x0000-0x7FFF | 0x0000-0xEFFF | 0x0000-0xEFFF |
| RAM (2 KB) | 0xC000-0xC7FF | 0xF000-0xF7FF | 0xF000-0xF7FF |
| Sound latch (read) | 0xC800 | 0xF800 | 0xF800 |
| YM #1 (addr/data) | 0xF000-0xF001 | 0xF802-0xF803 | YM2151 0xF808-0xF809 |
| YM #2 | 0xF002-0xF003 | 0xF804-0xF805 | - |
| OKI M6295 | - | - | 0xF80A |

gulfstrm's sound ROM is 0x10000 bytes (1946) but `lastday_sound_map`
only maps 0x0000-0x7FFF (981); lastday's sound ROM file is loaded so that
its second half lands at 0 (1839-1840, first half marked "empty").

Sound latch: `GENERIC_LATCH_8` with no data-pending callback (1471, 1488),
so there is no sound NMI and no main-CPU readback. The sound program
polls. The latch is a plain 8-bit register; reading does not clear it.

## 5. Interrupts and frame timing

### 5.1 Z80 games

- Main Z80: `set_vblank_int("screen", irq0_line_hold)` in every Z80
  config (1503, 1538, 1573, 1608, 1652, 1688). One INT per frame at
  vblank start, held until acknowledged. No vector callback is set, so
  MAME supplies the Z80 default vector 0xFF (z80.h,
  `execute_default_irq_vector` returns 0xff): RST 38h in IM0, ignored
  in IM1. The core should drive 0xFF on the acknowledge cycle.
- Sound Z80, YM2151 games: YM2151 IRQ drives Z80 INT directly (1491).
- Sound Z80, YM2203 games: both YM2203 IRQ outputs go into an
  `INPUT_MERGER_ANY_HIGH` whose output drives Z80 INT (1467, 1474,
  1479). **TODO(MAME):** this OR is a declared workaround "until we find
  real PCB and verify clocks and trace int lines" (47-67). The driver
  notes that with a single shared line an interrupt that fires while the
  other is being serviced is lost and one timer "never restarts".
- No NMI is used on either CPU.

### 5.2 68000 games

`TIMER_DEVICE` scanline callback over the 256-line screen (1720-1729,
1736, 1794):

| Line | Action |
|---|---|
| 248 | IPL5, HOLD_LINE ("vblank-out irq") |
| 120 | IPL6, HOLD_LINE ("timer irq?") |

MAME's 68000 uses autovectors when no acknowledge callback is set.
**OPEN:** the true source of the line-120 IRQ6 (the comment is a
question mark).

### 5.3 Screen parameters (all TODO(MAME))

Every config uses `set_refresh_hz(60)`, `set_size(512, 256)` and
`set_vblank_time(2500 us)`, not `set_raw`; the vblank time is annotated
"not accurate" in every config (1513, 1548, 1583, 1618, 1662, 1696,
1746, 1804).

| Configs | Visible area (x, y) | Size |
|---|---|---|
| all except primella | x 64-447, y 8-247 (1515 and equivalents) | 384 x 240 |
| primella (sadari, gundl94, primella) | x 64-447, y 0-255 (1698) | 384 x 256 |

Consequences of MAME's model (screen.cpp, MAME core):
- Frame = 256 lines, each 1/(60*256) s = 65.1 us.
- vblank starts at line 248 (first line after the visible area). The
  frame is rendered first, then the vblank callbacks run: sprite buffer
  copy and the Z80 vblank INT (screen.cpp `vblank_begin`: update, then
  callbacks, then `m_screen_vblank(1)`).
- The vblank signal stays asserted for 2.5 ms (about 38 lines), which
  runs into the next frame. This matters for the games that read vblank
  as an input bit (section 9).

PCB evidence in the driver: flytiger HSync 15.68 kHz, VSync 60 Hz
(2366-2367); superx HSync 15.68 kHz, VSync 60 Hz (2576-2577); popbingo
VSync 60 Hz (2796). **OPEN:** an 8 MHz pixel clock with 512 clocks per
line gives 15.625 kHz; 510 clocks gives 15.686 kHz, closer to the quoted
figure. Both boards (16 MHz and 8 MHz crystals) can produce 8 MHz. Total
lines are unknown: 15.68 kHz / 60 Hz is about 261. Treat the MAME
512 x 256 x 60 Hz geometry as a parity target only; real totals need a
recording or a scope (PLAN research item R1).

### 5.4 When the games write video registers (O10, answered from MAME logs)

MAME draws the whole frame once, at the start of line 248, from the
register, RAM and palette state at that instant (no Dooyong write forces a
partial update). Beam positions of every tilemap-register and control write
were logged for 12,000 attract frames of all ten parents
(`docs/m0_findings.md` section 4). Counting only writes that change a value
(the tilemap registers act on change only, 7.2) after the first 100 boot
frames:

| Game | Changes in visible lines 8-247 | Where |
|---|---|---|
| flytiger | 44 | 33 at lines 8-15 (vblank handler running into the first visible lines), the rest scattered; ctrl bit 4 (priority swap) changed mid-screen 3 times |
| bluehawk | 0 | all writes in vblank |
| gulfstrm | 54 | lines 8-31 |
| lastday | 89 | 14 at lines 8-23, 75 at lines 112-223 during scene changes |
| pollux | about 2,700 register changes plus 95,368 toggles of ctrl bit 2 | anywhere on screen; about a third of all pollux scroll changes land in the visible area, so it updates scroll outside the vblank handler |
| superx, rshark, popbingo | 20,412 / 15,822 / 12,422 | all but two at lines 120-135: the scroll updates are done in the line-120 IRQ6 handler (5.2) |
| sadari, gundl94 | n/a | primella config: visible area is lines 0-255, vblank starts at line 256 = 0, and the writes land in lines 0-10 |

Consequence: a core that reads the scroll registers live while scanning out
would split the picture at the write line on pollux and on all three 68000
games every frame (and at the top lines on flytiger/gulfstrm). MAME shows no
split. For MAME parity the RTL must latch the tilemap registers (and the
flytiger priority bit) once per frame at the vblank start, and draw the
whole frame from the latched copy. Whether the real boards latch like this
is not known; a split on real hardware would be visible in recordings of the
68000 games (the write line is fixed at about 123). This is a new research
item (PLAN R12).

## 6. Palette

MAME palette formats (emupal.h, MAME core): `xBGR_444` =
`xxxxBBBBGGGGRRRR`, `xRGB_555` = `xRRRRRGGGGGBBBBB`. Palette RAM written
by the Z80 is little-endian (low byte at the even address; the share
takes the CPU's endianness, and the banked version sets
`ENDIANNESS_LITTLE` explicitly at 204). 68000 palette words are
big-endian. The background fill (`black_pen`) is a pen outside palette
RAM that is always RGB 0,0,0 (dipalette.cpp, `black_entry`).

| Game | Format | Entries | CPU window | Line |
|---|---|---|---|---|
| lastday | xBGR_444 | 1024 | 0xC800-0xCFFF (2 KB) | 1521, 816 |
| gulfstrm | xRGB_555 | 1024 | 0xF800-0xFFFF | 1556, 857 |
| pollux | xRGB_555 | 2048 (4 KB backing) | 0xF800-0xFFFF, banked | 1591, 838 |
| bluehawk | xRGB_555 | 1024 | 0xC800-0xCFFF | 1626, 875 |
| flytiger | xRGB_555 | 2048 (4 KB backing) | 0xE800-0xEFFF, banked | 1670, 897 |
| primella family | xRGB_555 | 1024 | 0xF000-0xF7FF write-only | 1702, 908 |
| rshark, superx | xRGB_555 | 2048 | 4 KB, write-only | 1754, 934, 953 |
| popbingo | xRGB_555 | 2048 | 4 KB, write-only | 1812, 973 |

### 6.1 Palette banking (pollux, flytiger)

- CPU access: when the bank flag is set, the byte offset within the 2 KB
  window is ORed with 0x800 (180-192), so the CPU sees either the lower
  or upper 1024 entries.
- Display: the same flag adds 64 to the colour code of bg0, fg0 and text
  (`set_palette_bank(bank << 6)`, 453-455, 493-495; applied at
  tm.cpp:178 and tm.cpp:262) and of sprites (573). With 16 pens per
  colour this adds 1024 to every pen, selecting the upper half.
- pollux: bank = `pollux_ctrl_w` bit 1, only if the banked RAM exists
  (450). gulfstrm uses the same handler but never allocates banked RAM
  (286-292), so its bank stays 0.
- flytiger: bank = `flytiger_ctrl_w` bit 3 (488-496).
- Driver note: "both palettes are almost identical, except for much
  darker BG layer colors" (69-72).

### 6.2 Pen allocation per game (gfxdecode colour bases, 1380-1450)

Pen index = colour base + colour code x 16 + pixel value.

| Game | Text | Sprites | fg0 | bg0 | Other |
|---|---|---|---|---|---|
| lastday, gulfstrm | 0 | 256 | 512 | 768 | - |
| pollux, flytiger | 0 | 256 | 512 | 768 | +1024 when banked |
| bluehawk | 0 | 256 | 512 | 768 | fg1 base 0 (shares the text range) |
| primella family | 0 | none | 512 | 768 | 256-511 unused |
| rshark, superx | none | 0 | 512 | 1024 | fg1 256, bg1 768 |
| popbingo | none | 0 | none | see 11.9 | composite bg at 256-511 |

### 6.3 Power-on palette state (MAME artefact, M0)

MAME's pens start from a fixed default pattern (pen 0 black, 1 red, 15
white, ...) and each pen only follows palette RAM from the first write to
that entry (a write to either byte updates the pen from both RAM bytes).
The palette RAM itself starts at zero. For the first few frames after
reset, flytiger and bluehawk display pens that were never written, so MAME
shows colours (white screens, cyan/magenta bars) that do not come from RAM.
Real boards have undefined SRAM contents there. The oracle comparison
tracks written entries and takes MAME's pen colour for unwritten ones
(1 flytiger frame, 3 bluehawk frames in the M0 captures). The core should
not try to reproduce the MAME pattern.

## 7. ROM tilemap device (`dooyong_rom_tilemap_device`)

### 7.1 Geometry

- Each ROM layer is a MAME tilemap of `1024 / tile_width` columns by
  `m_rows` rows, scanned column-major (`TILEMAP_SCAN_COLS`, tm.cpp:113-120).
  `m_rows` is 8 by default (tm.cpp:64) and 32 for the R-Shark variant
  (tm.cpp:190).
  - 32x32 tiles (all Z80 games, popbingo): 32 columns x 8 rows = 1024 x 256 px.
  - 16x16 tiles (rshark, superx): 64 columns x 32 rows = 1024 x 512 px.
- Tile index inside the window: `col * rows + row`.
- ROM word index: `(tile_index + (reg1 * 256 / tile_width) * rows) & (length - 1)`,
  then `+ offset` (tm.h:79-80, tm.cpp:139-140). `length` must be a power
  of two for the mask to be correct.
- The map ROM is read as big-endian 16-bit words (`required_region_ptr<u16>`
  over a `ROM_REGION16_BE`; romload.cpp byte-swaps BE regions on a
  little-endian host so the u16 view is the logical BE value).

### 7.2 Registers (`ctrl_w`, tm.cpp:74-105)

8 registers (offset & 7). A write only takes effect if the value changes.

| Reg | Function |
|---|---|
| 0 | X scroll low byte. Sets the tilemap X scroll to this value only (0-255). |
| 1 | X scroll high byte. Selects which 256-pixel column block the 1024-px window starts at (via the ROM index above). Marks all tiles dirty. |
| 2 | Unknown. "initialised on startup by some games and written to continuously by others". |
| 3 | Y scroll low byte. |
| 4 | Y scroll high byte. Y scroll = reg3 or reg4 << 8; the tilemap wraps at its height (256 or 512). |
| 5 | Unknown, initialised on startup. |
| 6 | bit 4: layer disable (1 = off). bit 5: map word format select (7.3). Other bits unknown. |
| 7 | Unknown, initialised on startup. |

Effective model: the left edge of the visible area (screen x 64) shows
tilemap pixel `reg1 * 256 + reg0 + 64` of the whole ROM strip, i.e. a
16-bit X position. All registers reset to 0 (tm.cpp:130).

**O1, answered in M0 (was OPEN):** for 32x32 layers the reachable map
range is tile index 0-255 plus `reg1 * 64`, i.e. words 0x0000-0x40BF with
an 8-bit reg1. That matches the 0x4000-word maps of bluehawk, flytiger,
primella and popbingo; the R-Shark 16x16 layers (reg1 * 512 words per
step) cover their full 0x20000-word maps. lastday, gulfstrm and pollux
have dedicated 0x10000-word map ROM pairs (1860-1866, 1968-1974,
2143-2149). The ROM contents (`tools/analyze_maps.py`) show the extra three
quarters carry no map data:

| Map | Words 0x4000-0xFFFF | Last non-0xFFFF/0x0000 word |
|---|---|---|
| lastday bg0_tmap, fg0_tmap | all 0xFFFF | 0x2EE7, 0x11CD |
| gulfstrm bg0_tmap, fg0_tmap | all 0xFFFF | 0x353F, 0x2D5F |
| pollux bg0_tmap | all 0xFFFF | 0x28DF |
| pollux fg0_tmap | stale Z80 program, not map data (below) | 0xFFFE |

pollux fg0_tmap: in words 0x4000-0xFFFF both byte-lane EPROMs (pollux5,
pollux4) hold identical bytes, and those bytes are an older build of the
pollux main program: each 4 KB chunk at lane address A aligns with the
pollux main ROM at A plus 0 to 0x12A (0x115-0x12A for 0x4000-0x7FFF, 0xA0
for 0x8000-0xBFFF, 0 for 0xC000-0xFFFF), 41 to 99.9 percent byte-identical
per chunk. Map data would differ between the two lanes (it
does below 0x4000). These are reused EPROMs that were only partly
reprogrammed. The polluxn BAD_DUMP differs from pollux in 13 bytes, all in
the odd lane at words 0x4FDF-0x4FFF, i.e. inside this unused part.

Register 2 never extends the X position: over 12,000 attract frames it
holds one constant per game (0x00 on lastday, gulfstrm, pollux and the
68000 games; 0xFF on flytiger, bluehawk, sadari, gundl94), and the largest
reg1 values seen (lastday 0x48, gulfstrm 0xF0, pollux 0xE6) keep every
access below word 0x3D00. MAME's 16-bit X model is sufficient; the core
needs 15 map address bits (to reproduce the 0x40BF edge case exactly, keep
the `& (length - 1)` mask with length 0x10000 on these three games).
Registers 5 and 7 are also written once and never changed (flytiger 0xFE /
0x08, bluehawk 0x06 or 0x12 / 0xF7 or 0x00).

### 7.3 Map word formats (tm.cpp:137-181)

Selected per layer by register 6 bit 5.

Format A (bit 5 = 1; comment: lastday/gulfstrm/pollux/flytiger):

```
bit 15    : tile code bit 9
bits 14-11: colour (4 bits)
bit 10    : Y flip
bit 9     : X flip
bits 8-0  : tile code bits 8-0
```

Format B (bit 5 = 0; comment: bluehawk/primella/popbingo/rshark). The
game-specific callback receives `attr & 0x3FFF`; flips come from bits 15
and 14 in all cases:

| Game (callback) | Code | Colour | Line |
|---|---|---|---|
| default (no callback: lastday, gulfstrm, pollux, flytiger) | `attr & 0x3FF` | bits 13-10 | tm.cpp:170-174 |
| bluehawk, primella family (`bluehawk_tile_callback`) | `attr & 0x3FF` | bits 13-10 | 235-239 |
| rshark, superx (`rshark_tile_callback`) | `attr & 0x1FFF` | 0 (from colour ROM, 7.4) | 367-371 |
| popbingo (`popbingo_tile_callback`) | `attr & 0x7FF` | 0 | 405-409 |

Bit 15 = Y flip, bit 14 = X flip (tm.cpp:176). The bank offset (6.1) is
added to the colour in both formats (tm.cpp:178). Tile codes wrap modulo
the number of decoded tiles in the layer's graphics region.

Which format each game selects is decided at run time by the game
writing register 6.

**O9, answered in M0** (register 6 writes over 12,000 attract frames per
parent; a layer whose register 6 is never written stays 0 = format B):

| Game | bg0 | fg0 | bg1 | fg1 |
|---|---|---|---|---|
| lastday | A (0x2D/0x2F, 0x3D off) | A | - | - |
| gulfstrm | A (0x20, 0x30 off) | A | - | - |
| pollux | A (0x2F, 0x3F off) | A | - | - |
| flytiger | A (0x2F, 0x3F off) | A | - | - |
| bluehawk | B (0x00) | B (never written) | - | **A (0x20)** |
| sadari, gundl94 | B (0x00) | B (never written) | - | - |
| superx, rshark | B (0x00) | B (0x00) | B (never written) | B (never written) |
| popbingo | B (0x00) | - | B (never written) | - |

The one surprise is bluehawk fg1, which selects format A (so the
`bluehawk_tile_callback` is never used for it). The M0 renderer draws it
that way and matches MAME on every captured frame, with fg1 visibly
contributing in about half of them. Only flytiger, pollux, lastday and
gulfstrm ever disable a layer through bit 4.

### 7.4 R-Shark colour ROM (`rshark_rom_tilemap_device`, tm.cpp:184-211)

The colour of each tile comes from a separate 8-bit ROM (`tmap_hi`),
indexed with the same adjusted tile index as the map word:
`colour = bank | (tmap_hi[offset + (index & (len - 1))] & 0x0F)`
(tm.cpp:208-210). Only the low nibble is used. The superx PCB notes say
these ROMs hold "the upper 4 bits of the tilemap data" and have fixed
bits (2595-2597).

### 7.5 Per-game layer instances

Offsets and lengths are in 16-bit words. A negative offset is taken from
the end of the region (tm.cpp:124-125); a negative length means the
whole region (tm.cpp:127-128).

| Game | Layer | Tile gfx region | Tile | Map region, word offset, length | Transparent pen | Line |
|---|---|---|---|---|---|---|
| lastday, gulfstrm, pollux | bg0 | bg0 | 32x32 | bg0_tmap, 0, whole (0x10000) | none | 1522, 1557, 1592 |
| | fg0 | fg0 | 32x32 | fg0_tmap, 0, whole | 15 | 1523-1524 etc. |
| bluehawk | bg0 | bg0 | 32x32 | bg0, 0x3C000 (byte 0x78000), 0x4000 | none | 1628-1629 |
| | fg0 | fg0 | 32x32 | fg0, 0x3C000, 0x4000 | 15 | 1631-1633 |
| | fg1 | fg1 | 32x32 | fg1, 0x1C000 (byte 0x38000), 0x4000 | 15 | 1635-1637 |
| flytiger | bg0 | bg0 | 32x32 | bg0, 0x3C000, 0x4000 | 15 | 1671-1672 |
| | fg0 | fg0 | 32x32 | fg0, 0x3C000, 0x4000 | 15 | 1673-1674 |
| primella family | bg0 | bg0 | 32x32 | bg0, -0x4000 (= 0x1C000, byte 0x38000), 0x4000 | none | 1704-1705 |
| | fg0 | fg0 | 32x32 | fg0, -0x4000, 0x4000 | 15 | 1707-1709 |
| rshark, superx | bg0 | bg0 | 16x16 | bg0, 0, 0x20000; colour tmap_hi 0x60000, 0x20000 bytes | none | 1756-1757 |
| | bg1 | bg1 | 16x16 | bg1, 0, 0x20000; colour tmap_hi 0x40000 | 15 | 1759-1761 |
| | fg0 | fg0 | 16x16 | fg0, 0, 0x20000; colour tmap_hi 0x20000 | 15 | 1763-1765 |
| | fg1 | fg1 | 16x16 | fg1, 0, 0x20000; colour tmap_hi 0x00000 | 15 | 1767-1769 |
| popbingo | bg0 | bg0 | 32x32 | bg0, 0, 0x4000 | none | 1814-1815 |
| | bg1 | bg1 | 32x32 | bg1, 0, 0x4000 | none | 1817-1818 |

On bluehawk, flytiger, primella family, rshark, superx and popbingo the
map data and the tile graphics share one ROM region (the "tiles +
tilemaps (together!)" comments), so the map words are also decoded as
(meaningless) tiles.

## 8. Text layer (`dooyong_ram_tilemap_device`, tm.cpp:214-263)

- 64 x 32 tiles of 8x8 = 512 x 256 px, column-major scan, index =
  col * 32 + row (tm.cpp:236-243).
- 2048 x 16-bit entries (4 KB of CPU space), address masked to 11 bits
  (tm.h:141, tm.cpp:222).
- Entry: bits 15-12 colour, bits 11-0 char code (tm.cpp:256-262). No
  flip bits. Pen 15 transparent (tm.cpp:244).
- Two CPU byte layouts:
  - "lastday" layout (lastday, gulfstrm, pollux, flytiger): CPU offset
    bit 11 selects the byte lane. Offsets 0x000-0x7FF are the low bytes
    of entries 0-2047, 0x800-0xFFF the high bytes (156-166).
  - "bluehawk" layout (bluehawk, primella family): offset bit 0 selects
    the lane, entry = offset >> 1 (168-178).
- No X scroll. Y scroll is only set by lastday and gulfstrm: +8, or -8
  when flipped, every frame (595, 613). pollux, flytiger and bluehawk
  leave it at 0.
- The 68000 games have no text layer.
- lastday's `sprites_disabled` flag does not affect text.

## 9. Control registers, inputs and DIP switches

### 9.1 Control register bits

| Game | Handler | Bits |
|---|---|---|
| lastday | 422-435 | 0,1 coin counters; 3 used, unknown; 4 sprite disable; 6 flip |
| gulfstrm, pollux | 437-461 | 0 flip; 1 palette bank (pollux only, 6.1), comment "used but unknown"; 2 "continuously toggled (unknown)"; 4 "used but unknown - display disable?"; 6 coin counter 2; 7 coin counter 1 |
| flytiger | 481-500 | 0 flip; 1,2 "used but unknown"; 3 palette bank; 4 swap bg0/fg0 priority |
| primella family | 464-478 | 0-2 ROM bank; 3 text layer priority (11.8); 4 flip; 5 used, unknown |
| 68000 games | 325-334 | 0 flip; 4 `bg2_priority` (11.7); 5 used, unknown |
| bluehawk | 145-148 | flip = whole byte non-zero |

### 9.2 Z80 input ports (generic, 1012-1090)

All active low.

| Port | Bit 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| P1 / P2 | Right | Left | Down | Up | Button 1 | Button 2 | unknown | unknown |
| SYSTEM | Coin 1 | Start 1 | Coin 2 | Start 2 | Service 1 | unknown | unknown | unknown |

Per-game overrides:
- lastday SYSTEM (1193-1201): 0 Start1, 1 unknown, 2 Start2, 3 Tilt
  **active high** ("maybe, but I'm not sure"), 4 unknown, 5 Service1,
  6 Coin2, 7 Coin1.
- gulfstrm SYSTEM (1217-1225) and pollux SYSTEM (1231-1239): 0 Coin1,
  1 Coin2, 2 Service1, 3 unknown, 4 **vblank** (active low; "???" on
  gulfstrm, "palette cycle effects need this to work" on pollux),
  5 Start1, 6 Start2, 7 unknown.
- flytiger: a vblank input on SYSTEM bit 6 is present but commented out,
  "reference shots suggest not, maybe a debug port?" (1255).
- sadari: P1/P2 bit 6 = Button 3 (1274-1278).

### 9.3 Z80 DIP switches

Generic DSWA (1013-1041): SWA:1 service mode; SWA:2 coin type A/B;
SWA:3 demo sounds (default on); SWA:4 flip screen; SWA:5-6 coin A;
SWA:7-8 coin B. Coin tables differ with coin type (PORT_CONDITION on
bit 1). Default 0xFF.

Generic DSWB (1043-1059): SWB:1-2 lives (1/2/3/4 as 0x00/0x02/0x03/0x01,
default 3); SWB:3-4 difficulty; SWB:5-7 unused; SWB:8 continue (default
yes). Default 0xFF.

| Game | DSWB changes | Default DSWB |
|---|---|---|
| lastday (1183-1191) | SWB:5-6 bonus life (every 200k / every 240k / 280k / none); SWB:7 speed low/high (default high) | 0xFF |
| gulfstrm (1207-1215) | SWB:5-6 bonus (every 300k/400k/500k/none); SWB:7 "Power Rise(?)" | 0xFF |
| pollux, bluehawk | none | 0xFF |
| flytiger (1249-1252) | SWB:7 auto fire (default on) | 0xFF |
| sadari (1261-1272) | SWB:1-2 "Show Girl" (default 0x01); SWB:5 cabinet; SWB:7 "Girl Show Point" | 0xFD |
| gundl94, primella (1284-1292) | SWB:1-2 "Show Girl" (default 0x01); SWB:5 cabinet | 0xFD |

**TODO(MAME):** primella: does cocktail mode really exist, and are
buttons 2 and 3 used (39-41)?

### 9.4 68000 inputs and DIPs (1098-1172)

- DSW, 16 bits: low byte = SWA as in 9.3 DSWA, high byte = SWB as in
  9.3 DSWB. Default 0xFFFF.
- P1_P2, 16 bits: low byte P1, high byte P2, each Right, Left, Down, Up,
  Button 1-4, active low.
- SYSTEM: low byte as the Z80 generic SYSTEM; upper byte undefined in
  MAME.
- rshark: redefines Coin B with the same settings as the generic port
  (1298-1307).
- superx: SWA:1 becomes "Unknown" (documented as service mode "but it
  never had any effect in game", 1313-1316).
- popbingo (1322-1333): SWA:3 demo sounds with inverted polarity
  (default 0 = on), SWB:1 "VS Max Round", SWB:2 unknown, SWB:7
  "Blocks Don't Drop", SWB:8 unknown. Default 0xFFFB.

## 10. Sprites

### 10.1 Z80 sprites (`dooyong_z80_state::draw_sprites`, 503-586)

- Buffered sprite RAM: `BUFFERED_SPRITERAM8`, copied on the rising edge
  of vblank (1509, 1517 and equivalents). Rendering uses the copy, so
  sprite RAM written during frame N appears in frame N+1. Not present on
  the primella family.
- 4 KB = 128 entries of 32 bytes, processed from entry 0 upwards (529).
  There is no enable bit; every entry is drawn.
- Entry layout (505-526, 531-534):

| Byte | Bits |
|---|---|
| +0x00 | code bits 7-0 |
| +0x01 | bits 7-5 code bits 10-8; bit 4 X bit 8; bits 3-0 colour |
| +0x02 | Y (8 bits) |
| +0x03 | X bits 7-0 |
| +0x1C | extension byte, used only with the flags below |

- Extension flags per game (137-143, 544-563):

| Flag | Effect | lastday | gulfstrm | pollux | flytiger | bluehawk |
|---|---|---|---|---|---|---|
| SPRITE_12BIT | code bit 11 = ext bit 0 | - | yes | yes | yes | yes |
| SPRITE_HEIGHT | height = ext bits 6-4 (0-7 means 1-8 tiles tall); code &= ~height; X flip = ext bit 3; Y flip = ext bit 2 | - | - | yes | yes | yes |
| SPRITE_YSHIFT_BLUEHAWK | sy += 6 - ((~ext & 2) << 7): ext bit 1 = 0 gives sy + 6 - 256, bit 1 = 1 gives sy + 6 | - | - | - | - | yes |
| SPRITE_YSHIFT_FLYTIGER | sy -= (ext & 2) << 7: ext bit 1 = 1 gives sy - 256 | - | - | - | yes | - |

  Flags per screen_update: lastday none (602), gulfstrm 12BIT (619),
  pollux 12BIT|HEIGHT (633), flytiger 12BIT|HEIGHT|YSHIFT_FLYTIGER (655),
  bluehawk 12BIT|HEIGHT|YSHIFT_BLUEHAWK (671).
  Note: the driver comment (524-525) says X/Y flip is "only used by
  pollux and flytiger", but the code applies flips to bluehawk too.
- `code &= ~height` clears the bits that are set in the height value,
  not a power-of-two alignment mask (552). **OPEN:** reproduce as-is.
- Multi-tile sprites: tiles `code + y` for y = 0..height, stacked
  vertically every 16 px, reversed when Y-flipped (575-584).
- Screen flip: `sx = 498 - sx`, `sy = 240 - 16 * height - sy`, both
  flips inverted (565-571).
- Colour = low nibble, plus 64 when the palette bank is set (573).
- Pen 15 transparent.
- Sprites are 16x16 from region `sprite` with colour base 256
  (1381, 1397).
- lastday only: ctrl bit 4 suppresses the whole sprite pass (601-602).
- No wrap: MAME draws at the computed coordinates and clips. A sprite
  with Y near 255 on a game without the Y-shift extension cannot
  re-enter at the top.

### 10.2 68000 sprites (`dooyong_68k_state::draw_sprites`, 689-751)

- `BUFFERED_SPRITERAM16`, copied at vblank rising (1742, 1750, 1800,
  1808).
- 4 KB = 256 entries of 8 words, processed from the LAST entry down to
  entry 0 (711).
- Entry layout (691-708, 713-725):

| Word | Bits |
|---|---|
| 0 | bit 0 enable |
| 1 | bits 3-0 width - 1, bits 7-4 height - 1 (1 to 16 tiles each) |
| 3 | tile code (16 bits) |
| 4 | bits 8-0 X |
| 6 | bits 8-0 Y, signed 9-bit |
| 7 | bits 3-0 colour |

- Tiles are numbered row-major: for each row y, for each column x,
  code++ (733-748).
- No per-sprite flip. Screen flip sets both flips and uses
  `sx = 498 - 16 * width - sx`, `sy = 240 - 16 * height - sy` (723-731).
- Graphics: 16x16 from `sprite`, colour base 0 (1424-1426).

### 10.3 Sprite-to-sprite and sprite-to-layer priority (MAME core)

`prio_transpen` (drawgfxt.ipp `PIXEL_OP_REMAP_TRANSPEN_PRIORITY`,
drawgfx.cpp `pmask |= 1 << 31`) works as follows for every non-transparent
sprite pixel:
1. The pixel is drawn only if bit `pri[x]` of the mask is clear.
2. Whether drawn or not, `pri[x]` is set to 31.
3. Bit 31 is always set in the mask, so a later sprite can never draw
   over a pixel an earlier sprite touched.

Consequences:
- The first sprite processed wins. On Z80 games that is the lowest RAM
  entry; on 68000 games the highest.
- A sprite pixel hidden behind a tile layer still blocks later sprites
  at that pixel.

Tilemap drawing ORs its priority value into `pri[x]` for every opaque
pixel (tilemap.cpp `pri[i] = (pri[i] & pmask) | pcode` with mask 0xFF).
The priority values per layer are in section 11.

Z80 sprite masks (538): colour 0 or 15 use raw mask 0xFC, others 0xF0.
- 0xF0: hidden where `pri >= 4` (text layer, or bluehawk fg1).
- 0xFC: hidden where `pri >= 2` (the second-drawn ROM layer, text,
  bluehawk fg1).

68000 sprite masks (719): `GFX_PMASK_4` (0xF0F0: hidden where
`pri & 4`) always, plus `GFX_PMASK_2` (0xCCCC: hidden where `pri & 2`)
for colour 0 or 15 (drawgfx.h constants).

**TODO(MAME):** "This priority mechanism works for known games, but
seems a bit strange. Are we missing something?" (536-537, 717-718).

## 11. Screen composition per game

All updates first fill the bitmap with black and, except primella,
clear the priority bitmap to 0.

### 11.1 lastday (589-605)
bg0 (pri 1), fg0 (pri 2), text (pri 4, Y scroll 8), then sprites unless
disabled (no extension flags).

### 11.2 gulfstrm (607-622)
As lastday, sprites always drawn, SPRITE_12BIT.

### 11.3 pollux (624-636)
bg0 (1), fg0 (2), text (4, no Y offset), sprites 12BIT|HEIGHT.

### 11.4 flytiger (638-658)
If ctrl bit 4 is 0: bg0 (1), fg0 (2). If 1: fg0 (1), bg0 (2). Both
layers use transparent pen 15 here, so black shows through where both
are transparent. Then text (4), sprites 12BIT|HEIGHT|YSHIFT_FLYTIGER.

### 11.5 bluehawk (661-674)
bg0 (1), fg0 (2), fg1 (4), text (4), sprites
12BIT|HEIGHT|YSHIFT_BLUEHAWK. fg1 is above every sprite.

### 11.6 primella family (676-686)
No priority bitmap use, no sprites. bg0, then text if ctrl bit 3 = 1,
then fg0, then text if ctrl bit 3 = 0. The ctrl comment says bit 3
"disables tx layer" (469), but the code uses it to move text below fg0.

### 11.7 rshark, superx (754-767)
bg0 (1, opaque), bg1 (2 if `bg2_priority` else 1), fg0 (2), fg1 (2),
sprites. With bg0 opaque, the net rule: sprites with colour 0 or 15 go
behind fg0, fg1, and bg1 when `bg2_priority` = 1; all other sprites are
above every layer (pri never reaches 4 on these games).

### 11.8 primella text priority
See 11.6.

### 11.9 popbingo (770-793)
bg0 and bg1 are drawn into two private bitmaps (both opaque, colour 0,
colour base 0, so each pixel holds the raw 4-bit pen 0-15). The final
pixel is `0x100 | (bg0 << 4) | bg1` (787): the two 4-bit layers form an
8-bit index into palette entries 256-511. Sprites are then drawn over
the result; the priority bitmap only ever holds 1, so no sprite is
hidden. Edge case: if a bg layer is disabled through register 6, its
private bitmap keeps the black-pen fill value and the composite index is
out of range.

### 11.10 Flip handling
`flip_screen_set` flips all tilemaps globally (driver_device). MAME
computes flipped scroll per tilemap as
`screen_width - tilemap_width - (dx_flipped - scroll)` with
`screen_width` = 512 (tilemap.cpp `effective_rowscroll` /
`effective_colscroll`). The RTL must port that exact formula for parity
in flipped mode. Sprites use the constants in 10.1 and 10.2.

Closed form (derived in M0 and verified pixel-exact on 600 flipped
flytiger and bluehawk frames): the tilemap pixmap is drawn with its origin
at that effective scroll and, when flipped, holds the logical tilemap
mirrored, so for screen bitmap coordinates (x 0-511, y 0-255):

```
normal : tx = (x + scrollx) mod W          ty = (y + scrolly) mod H
flipped: tx = (scrollx + 511 - x) mod W    ty = (scrolly + 255 - y) mod H
```

with W, H the tilemap size (1024 x 256 for 32x32 layers, 512 x 256 for
text). Text uses scrollx 0 and scrolly 0 (8 or -8 on lastday/gulfstrm, 8.x).
A first attempt that used `+ (512 - W + scroll)` as a forward offset failed
on every flipped frame, so the sign matters.

## 12. Graphics decode layouts (1342-1450)

All layouts address a logical big-endian byte stream: for 16-bit BE
regions MAME's decoder compensates for the host byte swap (digfx.cpp
xormask), so byte 2n is the high byte of word n. In MAME layouts, bit
offset 0 is the MSB of byte 0 and the first plane is the MSB of the pen.

`ROM_LOAD16_BYTE` at offset 0 fills the high (even) byte lane.
`ROM_LOAD16_WORD_SWAP` into a BE region means the file holds
little-endian words: word n = file[2n] | file[2n+1] << 8.

| Layout | Used by | Size | Bytes/tile | Pixel format |
|---|---|---|---|---|
| `tilelayout` (1353-1367) | 32x32 ROM layers | 32x32x4 | 512 | Planes at bit offsets 0,4,8,12. Pixels x0-3 at bits 0-3 and x4-7 at bits 16-19 of a 32-bit row group; each further 8-px column is +1024 bits (128 bytes). Row stride 32 bits. Per row group of 4 bytes: byte 0 high nibble = plane 0 of px 0-3, byte 0 low nibble = plane 1, byte 1 high = plane 2, byte 1 low = plane 3; bytes 2-3 same for px 4-7. |
| `spritelayout` (1369-1378) | Z80 sprites; rshark/superx 16x16 ROM layers | 16x16x4 | 128 | Same nibble-plane packing; px 0-7 in bytes 0-3 of each row, px 8-15 at +64 bytes. Row stride 4 bytes. |
| `lastday_charlayout` (1342-1351) | text on lastday, gulfstrm, pollux, flytiger | 8x8x4 | 16 + 16 | `RGN_FRAC(1,2)`: planes 0,1 from the first half of the region, planes 2,3 from the same offset in the second half. Per row 2 bytes per half; byte high nibble = plane (0 or 2) of 4 px, low nibble = plane (1 or 3). |
| `gfx_8x8x4_packed_msb` (generic.cpp) | text on bluehawk, primella family | 8x8x4 | 32 | Packed 4 bpp, high nibble first, 4 bytes per row. |
| `gfx_8x8x4_col_2x2_group_packed_msb` (generic.cpp) | 68000 sprites | 16x16x4 | 128 | Packed 4 bpp, high nibble first; left 8 px of each row in bytes 0-3 (rows at 4-byte stride), right 8 px at +64 bytes. |

Decoded element counts (region bytes / bytes per tile; codes wrap modulo
this count):

| Game | Text chars | Sprites | bg0 | fg0 | Other |
|---|---|---|---|---|---|
| lastday | 1024 (0x8000 / 32) | 2048 | 1024 | 512 | - |
| gulfstrm | 1024 | 4096 | 1024 | 512 | - |
| pollux | 2048 | 4096 | 1024 | 1024 (upper half 0xFF fill) | - |
| bluehawk | 2048 | 4096 | 1024 | 1024 | fg1 512 |
| flytiger | 2048 | 4096 | 1024 | 1024 | - |
| sadari | 4096 | - | 1024 | 1024 | - |
| gundl94, primella | 4096 | - | 512 | 512 | - |
| rshark, superx | - | 16384 | 8192 | 8192 | bg1, fg1 8192 each |
| popbingo | - | 8192 | 2048 | - | bg1 2048 |

Region load quirks:
- lastday/gulfstrm text: file 0x10000, `ROM_CONTINUE` at 0 overwrites
  the first half, so the region is the file's second half (1843-1844,
  1949-1950; first half marked "empty").
- pollux/flytiger text: file halves are swapped into the region (second
  half at 0x0000, first at 0x8000) (2129-2130, 2404-2405).
- pollux fg0: 0x40000-0x7FFFF filled with 0xFF (2141).
- flytigera: the same bg0/fg0 data split across eight 128 KB ROMs, with
  odd-lane files listed first (2440-2450).

## 13. ROM sets

Generated from the ROM_START blocks (script in the scratchpad, output
checked against the source line numbers). "Bytes" is the file size;
`LOAD + CONTINUE` rows load a file in two halves. Region sizes include
fill and unused space. Clone tables list only files whose content (CRC)
or placement differs from the parent; all other files are identical in
content, though names may differ.

#### `lastday` (dooyong.cpp:1833-1867)

Regions: maincpu 0x20000, audiocpu 0x10000, tx 0x8000, sprite 0x40000, bg0 0x80000, fg0 0x40000, bg0_tmap 0x20000, fg0_tmap 0x20000

| Region | File | Offset | Bytes | Load | CRC32 | Line |
|---|---|---|---|---|---|---|
| maincpu | lday3.s5 | 0x000000 | 0x010000 | LOAD | a06dfb1e | 1835 |
| maincpu | 4.u5 | 0x010000 | 0x010000 | LOAD | 70961ea6 | 1836 |
| audiocpu | 1.d3 | 0x000000 | 0x010000 | LOAD + CONTINUE@0x00000 | dd4316fd | 1839 |
| tx | 2.j4 | 0x000000 | 0x010000 | LOAD + CONTINUE@0x00000 | 83eb572c | 1843 |
| sprite | 16.d14 | 0x000000 | 0x020000 | 16_BYTE | df503504 | 1847 |
| sprite | 15.a14 | 0x000001 | 0x020000 | 16_BYTE | cd990442 | 1848 |
| bg0 | 6.s9 | 0x000000 | 0x020000 | 16_BYTE | 1054361d | 1851 |
| bg0 | 9.s11 | 0x000001 | 0x020000 | 16_BYTE | 6952ef4d | 1852 |
| bg0 | 7.u9 | 0x040000 | 0x020000 | 16_BYTE | 6e57a888 | 1853 |
| bg0 | 10.u11 | 0x040001 | 0x020000 | 16_BYTE | a5548dca | 1854 |
| fg0 | 12.s13 | 0x000000 | 0x020000 | 16_BYTE | 992bc4af | 1857 |
| fg0 | 14.s14 | 0x000001 | 0x020000 | 16_BYTE | a79abc85 | 1858 |
| bg0_tmap | 5.r9 | 0x000000 | 0x010000 | 16_BYTE | 4789bae8 | 1861 |
| bg0_tmap | 8.r11 | 0x000001 | 0x010000 | 16_BYTE | 92402b9a | 1862 |
| fg0_tmap | 11.r13 | 0x000000 | 0x010000 | 16_BYTE | 04b961de | 1865 |
| fg0_tmap | 13.r14 | 0x000001 | 0x010000 | 16_BYTE | 6bdbd887 | 1866 |

File bytes 1536 KB; region bytes 1504 KB.

Clone `lastdaya` (1869-1903), 5 files differ:

| Region | File | Offset | Bytes | Load | CRC32 | Line |
|---|---|---|---|---|---|---|
| audiocpu | e1.d3 | 0x000000 | 0x010000 | LOAD + CONTINUE@0x00000 | ce96e106 | 1875 |
| bg0 | e6.s9 | 0x000000 | 0x020000 | 16_BYTE | 7623c443 | 1887 |
| bg0 | e9.s11 | 0x000001 | 0x020000 | 16_BYTE | 717f6a0e | 1888 |
| bg0_tmap | e5.r9 | 0x000000 | 0x010000 | 16_BYTE | 5f801410 | 1897 |
| bg0_tmap | e8.r11 | 0x000001 | 0x010000 | 16_BYTE | a7b8250b | 1898 |

Clone `ddaydoo` (1905-1939), 1 file differs:

| Region | File | Offset | Bytes | Load | CRC32 | Line |
|---|---|---|---|---|---|---|
| maincpu | 3.s5 | 0x000000 | 0x010000 | LOAD | 7817d4f3 | 1907 |

#### `gulfstrm` (dooyong.cpp:1941-1975)

Regions: maincpu 0x20000, audiocpu 0x10000, tx 0x8000, sprite 0x80000, bg0 0x80000, fg0 0x40000, bg0_tmap 0x20000, fg0_tmap 0x20000

| Region | File | Offset | Bytes | Load | CRC32 | Line |
|---|---|---|---|---|---|---|
| maincpu | 1.l4 | 0x000000 | 0x020000 | LOAD | 59e0478b | 1943 |
| audiocpu | 3.c5 | 0x000000 | 0x010000 | LOAD | c029b015 | 1946 |
| tx | 2.s4 | 0x000000 | 0x010000 | LOAD + CONTINUE@0x00000 | c2d65a25 | 1949 |
| sprite | 14.b1 | 0x000000 | 0x020000 | 16_BYTE | 67bdf73d | 1953 |
| sprite | 16.c1 | 0x000001 | 0x020000 | 16_BYTE | 7770a76f | 1954 |
| sprite | 15.b1 | 0x040000 | 0x020000 | 16_BYTE | 84803f7e | 1955 |
| sprite | 17.e1 | 0x040001 | 0x020000 | 16_BYTE | 94706500 | 1956 |
| bg0 | 4.d8 | 0x000000 | 0x020000 | 16_BYTE | 858fdbb6 | 1959 |
| bg0 | 5.b9 | 0x000001 | 0x020000 | 16_BYTE | c0a552e8 | 1960 |
| bg0 | 6.d8 | 0x040000 | 0x020000 | 16_BYTE | 20eedda3 | 1961 |
| bg0 | 7.d9 | 0x040001 | 0x020000 | 16_BYTE | 294f8c40 | 1962 |
| fg0 | 12.r8 | 0x000000 | 0x020000 | 16_BYTE | ec3ad3e7 | 1965 |
| fg0 | 13.r9 | 0x000001 | 0x020000 | 16_BYTE | c64090cb | 1966 |
| bg0_tmap | 8.e8 | 0x000000 | 0x010000 | 16_BYTE | 8d7f4693 | 1969 |
| bg0_tmap | 9.e9 | 0x000001 | 0x010000 | 16_BYTE | 34d440c4 | 1970 |
| fg0_tmap | 10.n8 | 0x000000 | 0x010000 | 16_BYTE | b4f15bf4 | 1973 |
| fg0_tmap | 11.n9 | 0x000001 | 0x010000 | 16_BYTE | 7dfe4a9c | 1974 |

File bytes 1792 KB; region bytes 1760 KB. Only the first 32 KB of the
sound ROM is mapped (section 4).

Clone `gulfstrma` (1977-2011), 5 files differ:

| Region | File | Offset | Bytes | Load | CRC32 | Line |
|---|---|---|---|---|---|---|
| maincpu | 1.bin | 0x000000 | 0x020000 | LOAD | d04fb06b | 1979 |
| fg0 | 12.bin | 0x000000 | 0x020000 | 16_BYTE | 3e3d3b57 | 2001 |
| fg0 | 13.bin | 0x000001 | 0x020000 | 16_BYTE | 66fcce80 | 2002 |
| fg0_tmap | 10.bin | 0x000000 | 0x010000 | 16_BYTE | 08149140 | 2009 |
| fg0_tmap | 11.bin | 0x000001 | 0x010000 | 16_BYTE | 2ed7545b | 2010 |

Clone `gulfstrmb` (2013-2047), 5 files differ:

| Region | File | Offset | Bytes | Load | CRC32 | Line |
|---|---|---|---|---|---|---|
| maincpu | 1.l4 | 0x000000 | 0x020000 | LOAD | aabd95a5 | 2015 |
| fg0 | 12.bin | 0x000000 | 0x020000 | 16_BYTE | 3e3d3b57 | 2037 |
| fg0 | 13.bin | 0x000001 | 0x020000 | 16_BYTE | 66fcce80 | 2038 |
| fg0_tmap | 10.bin | 0x000000 | 0x010000 | 16_BYTE | 08149140 | 2045 |
| fg0_tmap | 11.bin | 0x000001 | 0x010000 | 16_BYTE | 2ed7545b | 2046 |

Clone `gulfstrmm` (2049-2083), 6 files differ:

| Region | File | Offset | Bytes | Load | CRC32 | Line |
|---|---|---|---|---|---|---|
| maincpu | 18.l4 | 0x000000 | 0x020000 | LOAD | d38e2667 | 2051 |
| tx | 2.bin | 0x000000 | 0x010000 | LOAD + CONTINUE@0x00000 | cb555d96 | 2057 |
| fg0 | 12.bin | 0x000000 | 0x020000 | 16_BYTE | 3e3d3b57 | 2073 |
| fg0 | 13.bin | 0x000001 | 0x020000 | 16_BYTE | 66fcce80 | 2074 |
| fg0_tmap | 10.bin | 0x000000 | 0x010000 | 16_BYTE | 08149140 | 2081 |
| fg0_tmap | 11.bin | 0x000001 | 0x010000 | 16_BYTE | 2ed7545b | 2082 |

Clone `gulfstrmk` (2085-2119), 6 files differ:

| Region | File | Offset | Bytes | Load | CRC32 | Line |
|---|---|---|---|---|---|---|
| maincpu | 18.4l | 0x000000 | 0x020000 | LOAD | 02bcf56d | 2087 |
| tx | 2.bin | 0x000000 | 0x010000 | LOAD + CONTINUE@0x00000 | cb555d96 | 2093 |
| fg0 | 12.bin | 0x000000 | 0x020000 | 16_BYTE | 3e3d3b57 | 2109 |
| fg0 | 13.bin | 0x000001 | 0x020000 | 16_BYTE | 66fcce80 | 2110 |
| fg0_tmap | 10.bin | 0x000000 | 0x010000 | 16_BYTE | 08149140 | 2117 |
| fg0_tmap | 11.bin | 0x000001 | 0x010000 | 16_BYTE | 2ed7545b | 2118 |

#### `pollux` (dooyong.cpp:2121-2150)

Regions: maincpu 0x20000, audiocpu 0x10000, tx 0x10000, sprite 0x80000, bg0 0x80000, fg0 0x80000, bg0_tmap 0x20000, fg0_tmap 0x20000

| Region | File | Offset | Bytes | Load | CRC32 | Line |
|---|---|---|---|---|---|---|
| maincpu | pollux2.bin | 0x000000 | 0x010000 | LOAD | 45e10d4e | 2123 |
| audiocpu | pollux3.bin | 0x000000 | 0x010000 | LOAD | 85a9dc98 | 2126 |
| tx | pollux1.bin | 0x008000 | 0x010000 | LOAD + CONTINUE@0x00000 | 7f7135da | 2129 |
| sprite | dy-pl-m2_be023.bin | 0x000000 | 0x080000 | WORD_SWAP | bdea6f7d | 2133 |
| bg0 | dy-pl-m1_be015.bin | 0x000000 | 0x080000 | WORD_SWAP | 1d2dedd2 | 2136 |
| fg0 | pollux6.bin | 0x000000 | 0x020000 | 16_BYTE | b0391db5 | 2139 |
| fg0 | pollux7.bin | 0x000001 | 0x020000 | 16_BYTE | 632f6e10 | 2140 |
| fg0 | (fill 0xFF) | 0x040000 | 0x040000 | FILL | - | 2141 |
| bg0_tmap | pollux9.bin | 0x000000 | 0x010000 | 16_BYTE | 378d8914 | 2144 |
| bg0_tmap | pollux8.bin | 0x000001 | 0x010000 | 16_BYTE | 8859fa70 | 2145 |
| fg0_tmap | pollux5.bin | 0x000000 | 0x010000 | 16_BYTE | ac090d34 | 2148 |
| fg0_tmap | pollux4.bin | 0x000001 | 0x010000 | 16_BYTE | 2c6bd3be | 2149 |

File bytes 1728 KB; region bytes 2048 KB.

Clone `polluxa` (2152-2181), 2 files differ:

| Region | File | Offset | Bytes | Load | CRC32 | Line |
|---|---|---|---|---|---|---|
| maincpu | dooyong2.bin | 0x000000 | 0x010000 | LOAD | e4ea8dbd | 2154 |
| tx | dooyong1.bin | 0x008000 | 0x010000 | LOAD + CONTINUE@0x00000 | a7d820b2 | 2160 |

Clone `polluxa2` (2183-2212), 2 files differ:

| Region | File | Offset | Bytes | Load | CRC32 | Line |
|---|---|---|---|---|---|---|
| maincpu | dooyong16_tms27c512.bin | 0x000000 | 0x010000 | LOAD | dffe5173 | 2185 |
| tx | dooyong1.bin | 0x008000 | 0x010000 | LOAD + CONTINUE@0x00000 | a7d820b2 | 2191 |

Clone `polluxn` (2214-2243), 2 files differ (file names all prefixed
`polluxntc_`):

| Region | File | Offset | Bytes | Load | CRC32 | Line |
|---|---|---|---|---|---|---|
| maincpu | polluxntc_2.3g | 0x000000 | 0x010000 | LOAD | 96d3e3af | 2216 |
| fg0_tmap | polluxntc_4.8r | 0x000001 | 0x010000 | 16_BYTE | 0195dc4e BAD_DUMP | 2242 |

The polluxn BAD_DUMP is "the same as other sets except it has some bits
of data blanked out with 0xFF" (2242).

#### `bluehawk` (dooyong.cpp:2246-2271)

Regions: maincpu 0x20000, audiocpu 0x10000, tx 0x10000, sprite 0x80000, bg0 0x80000, fg0 0x80000, fg1 0x40000, oki 0x40000

| Region | File | Offset | Bytes | Load | CRC32 | Line |
|---|---|---|---|---|---|---|
| maincpu | rom19 | 0x000000 | 0x020000 | LOAD | 24149246 | 2248 |
| audiocpu | rom1 | 0x000000 | 0x010000 | LOAD | eef22920 | 2251 |
| tx | rom3 | 0x000000 | 0x010000 | LOAD | c192683f | 2254 |
| sprite | dy-bh-m3 | 0x000000 | 0x080000 | WORD_SWAP | 8809d157 | 2257 |
| bg0 | dy-bh-m1 | 0x000000 | 0x080000 | WORD_SWAP | 51816b2c | 2260 |
| fg0 | dy-bh-m2 | 0x000000 | 0x080000 | WORD_SWAP | f9daace6 | 2263 |
| fg1 | rom6 | 0x000000 | 0x020000 | 16_BYTE | e6bd9daa | 2266 |
| fg1 | rom5 | 0x000001 | 0x020000 | 16_BYTE | 5c654dc6 | 2267 |
| oki | rom4 | 0x000000 | 0x020000 | LOAD | f7318919 | 2270 |

File bytes 2176 KB; region bytes 2304 KB.

Clone `bluehawkn` (2273-2298), 1 file differs:

| Region | File | Offset | Bytes | Load | CRC32 | Line |
|---|---|---|---|---|---|---|
| tx | rom3ntc | 0x000000 | 0x010000 | LOAD | 31eb221a | 2281 |

Clone `bluehawkna` (2300-2325), 2 files differ:

| Region | File | Offset | Bytes | Load | CRC32 | Line |
|---|---|---|---|---|---|---|
| maincpu | rom2 | 0x000000 | 0x020000 | LOAD | e5579e7a | 2302 |
| tx | rom3ntc | 0x000000 | 0x010000 | LOAD | 31eb221a | 2308 |

#### `flytiger` (dooyong.cpp:2396-2421)

Regions: maincpu 0x20000, audiocpu 0x10000, tx 0x10000, sprite 0x80000, bg0 0x80000, fg0 0x80000, oki 0x80000

| Region | File | Offset | Bytes | Load | CRC32 | Line |
|---|---|---|---|---|---|---|
| maincpu | 1.3c | 0x000000 | 0x020000 | LOAD | 2d634c8e | 2398 |
| audiocpu | 3.6p | 0x000000 | 0x010000 | LOAD | d238df5e | 2401 |
| tx | 2.4h | 0x008000 | 0x010000 | LOAD + CONTINUE@0x00000 | 2fb72912 | 2404 |
| sprite | 16.4h | 0x000000 | 0x020000 | 16_BYTE | 8a158b95 | 2408 |
| sprite | 15.2h | 0x000001 | 0x020000 | 16_BYTE | 399f6043 | 2409 |
| sprite | 14.4k | 0x040000 | 0x020000 | 16_BYTE | df66b6f3 | 2410 |
| sprite | 13.2k | 0x040001 | 0x020000 | 16_BYTE | f24a5099 | 2411 |
| bg0 | dy-ft-m1.11n | 0x000000 | 0x080000 | WORD_SWAP | f06589c2 | 2414 |
| fg0 | dy-ft-m2.11g | 0x000000 | 0x080000 | WORD_SWAP | 7545f9c9 | 2417 |
| oki | 4.9n | 0x000000 | 0x020000 | LOAD | cd95cf9a | 2420 |

File bytes 1920 KB; region bytes 2304 KB (OKI region 512 KB with 128 KB
loaded).

Clone `flytigera` (2423-2454, "alt pcb type"), 10 files differ (bg0/fg0
split into 128 KB byte-lane ROMs; all other content identical, names
prefixed `ftiger_`):

| Region | File | Offset | Bytes | Load | CRC32 | Line |
|---|---|---|---|---|---|---|
| maincpu | ftiger_1.3c | 0x000000 | 0x020000 | LOAD | 02acd1ce | 2425 |
| tx | ftiger_2.4h | 0x008000 | 0x010000 | LOAD + CONTINUE@0x00000 | ca9d6713 | 2431 |
| bg0 | ftiger_3.10p | 0x000001 | 0x020000 | 16_BYTE | 9fc12ebd | 2441 |
| bg0 | ftiger_5.10l | 0x000000 | 0x020000 | 16_BYTE | 06c9dd2a | 2442 |
| bg0 | ftiger_4.11p | 0x040001 | 0x020000 | 16_BYTE | fb30e884 | 2443 |
| bg0 | ftiger_6.11l | 0x040000 | 0x020000 | 16_BYTE | dfb85152 | 2444 |
| fg0 | ftiger_8.11h | 0x000001 | 0x020000 | 16_BYTE | cbd8c22f | 2447 |
| fg0 | ftiger_10.11f | 0x000000 | 0x020000 | 16_BYTE | e2175f3b | 2448 |
| fg0 | ftiger_7.10h | 0x040001 | 0x020000 | 16_BYTE | be431c61 | 2449 |
| fg0 | ftiger_9.10f | 0x040000 | 0x020000 | 16_BYTE | 91bcd84f | 2450 |

#### `sadari` (dooyong.cpp:2456-2482)

Regions: maincpu 0x20000, audiocpu 0x10000, tx 0x20000, bg0 0x80000, fg0 0x80000, oki 0x40000

| Region | File | Offset | Bytes | Load | CRC32 | Line |
|---|---|---|---|---|---|---|
| maincpu | 1.3d | 0x000000 | 0x020000 | LOAD | bd953217 | 2458 |
| audiocpu | 3.6r | 0x000000 | 0x010000 | LOAD | 4786fca6 | 2461 |
| tx | 2.4c | 0x000000 | 0x020000 | LOAD | b2a3f1c6 | 2464 |
| bg0 | 10.10l | 0x000000 | 0x020000 | 16_BYTE | 70269ab1 | 2469 |
| bg0 | 5.8l | 0x000001 | 0x020000 | 16_BYTE | ceceb4c3 | 2470 |
| bg0 | 9.10n | 0x040000 | 0x020000 | 16_BYTE | 21bd1bda | 2471 |
| bg0 | 4.8n | 0x040001 | 0x020000 | 16_BYTE | cd318ae5 | 2472 |
| fg0 | 11.10j | 0x000000 | 0x020000 | 16_BYTE | 62a1d580 | 2475 |
| fg0 | 6.8j | 0x000001 | 0x020000 | 16_BYTE | c4b13ed7 | 2476 |
| fg0 | 12.10g | 0x040000 | 0x020000 | 16_BYTE | 547b7645 | 2477 |
| fg0 | 7.8g | 0x040001 | 0x020000 | 16_BYTE | 14f20fa3 | 2478 |
| oki | 8.10r | 0x000000 | 0x020000 | LOAD | 9c29a093 | 2481 |

File bytes 1472 KB; region bytes 1600 KB. Note sadari's bg0/fg0 are
0x80000 while the primella machine config places the map at -0x4000
words from the region end (byte 0x78000 here, 0x38000 on gundl94).

#### `gundl94` (dooyong.cpp:2484-2514)

Regions: maincpu 0x20000, audiocpu 0x10000, tx 0x20000, bg0 0x40000, fg0 0x40000, oki 0x40000, cpu2 0x30000, gfx4 0x40000

| Region | File | Offset | Bytes | Load | CRC32 | Line |
|---|---|---|---|---|---|---|
| maincpu | gd94_001.d3 | 0x000000 | 0x020000 | LOAD | 3a5cc045 | 2486 |
| audiocpu | gd94_003.r6 | 0x000000 | 0x010000 | LOAD | ea41c4ad | 2489 |
| tx | gd94_002.c5 | 0x000000 | 0x020000 | LOAD | 8575e64b | 2492 |
| bg0 | gd94_009.n9 | 0x000000 | 0x020000 | 16_BYTE | 40eabf55 | 2497 |
| bg0 | gd94_004.n7 | 0x000001 | 0x020000 | 16_BYTE | 0654abb9 | 2498 |
| fg0 | gd94_012.g9 | 0x000000 | 0x020000 | 16_BYTE | 117c693c | 2501 |
| fg0 | gd94_007.g7 | 0x000001 | 0x020000 | 16_BYTE | 96a72c6d | 2502 |
| oki | gd94_008.r9 | 0x000000 | 0x020000 | LOAD | f92e5803 | 2505 |
| cpu2 | gd94_011.j9 | 0x000000 | 0x020000 | LOAD + RELOAD@0x10000 | d8ad0208 | 2508 |
| gfx4 | gd94_006.j7 | 0x000000 | 0x020000 | 16_BYTE | 1d9536fe | 2512 |
| gfx4 | gd94_010.l7 | 0x000001 | 0x020000 | 16_BYTE | 4b74857f | 2513 |

The `cpu2` and `gfx4` ROMs "don't seem to belong to this game" and are
not used by the machine config (2507-2513). The core does not need them.

Clone `primella` (2516-2538), 5 files differ (no cpu2/gfx4 regions):

| Region | File | Offset | Bytes | Load | CRC32 | Line |
|---|---|---|---|---|---|---|
| maincpu | 1_d3.bin | 0x000000 | 0x020000 | LOAD | 82fea4e0 | 2518 |
| bg0 | 7_n9.bin | 0x000000 | 0x020000 | 16_BYTE | 20b6a574 | 2529 |
| bg0 | 4_n7.bin | 0x000001 | 0x020000 | 16_BYTE | fe593666 | 2530 |
| fg0 | 8_g9.bin | 0x000000 | 0x020000 | 16_BYTE | 542ecb83 | 2533 |
| fg0 | 5_g7.bin | 0x000001 | 0x020000 | 16_BYTE | 058ecac6 | 2534 |

#### `superx` (dooyong.cpp:2602-2638)

Regions: maincpu 0x40000, audiocpu 0x10000, sprite 0x200000, fg1 0x100000, fg0 0x100000, bg1 0x100000, bg0 0x100000, tmap_hi 0x80000, oki 0x40000

| Region | File | Offset | Bytes | Load | CRC32 | Line |
|---|---|---|---|---|---|---|
| maincpu | 2.3m | 0x000000 | 0x020000 | 16_BYTE | be7aebe7 | 2604 |
| maincpu | 3.3l | 0x000001 | 0x020000 | 16_BYTE | dc4a25fc | 2605 |
| audiocpu | 1.5u | 0x000000 | 0x010000 | LOAD | 6894ce05 | 2608 |
| sprite | spxo-m05.10m | 0x000000 | 0x200000 | WORD_SWAP | 9120dd84 | 2611 |
| fg1 | spxb-m04.8f | 0x000000 | 0x100000 | WORD_SWAP | 91a7ac6e | 2614 |
| fg0 | spxb-m03.8j | 0x000000 | 0x100000 | WORD_SWAP | 8b42861b | 2618 |
| bg1 | spxb-m02.8a | 0x000000 | 0x100000 | WORD_SWAP | 21b8db78 | 2622 |
| bg0 | spxb-m01.8c | 0x000000 | 0x100000 | WORD_SWAP | 60c69129 | 2626 |
| tmap_hi | spxb-ms3.10f | 0x000000 | 0x020000 | LOAD | 8bf8c77d | 2630 |
| tmap_hi | spxb-ms4.10j | 0x020000 | 0x020000 | LOAD | d418a900 | 2631 |
| tmap_hi | spxb-ms2.10a | 0x040000 | 0x020000 | LOAD | 5ec87adf | 2632 |
| tmap_hi | spxb-ms1.10c | 0x060000 | 0x020000 | LOAD | 40b4fe6c | 2633 |
| oki | 4.7v | 0x000000 | 0x020000 | LOAD | 434290b5 | 2636 |
| oki | 5.7u | 0x020000 | 0x020000 | LOAD | ebe6abb4 | 2637 |

File and region bytes 7232 KB. The layer comments (bomb = fg1, title
logo = fg0, upper title background = bg1, lower = bg0) agree with the
tmap_hi offsets in 7.5.

Clone `superxm` (2641-2677), 3 files differ ("this set only had 68k
roms, sound program, and samples", 2640; graphics are borrowed from
superx):

| Region | File | Offset | Bytes | Load | CRC32 | Line |
|---|---|---|---|---|---|---|
| maincpu | 2_m.3m | 0x000000 | 0x020000 | 16_BYTE | 41c50aac | 2643 |
| maincpu | 3_m.3l | 0x000001 | 0x020000 | 16_BYTE | 6738b703 | 2644 |
| audiocpu | 1_m.5u | 0x000000 | 0x010000 | LOAD | 319fa632 | 2647 |

#### `rshark` (dooyong.cpp:2679-2718)

Regions: maincpu 0x40000, audiocpu 0x10000, sprite 0x200000, fg1 0x100000, fg0 0x100000, bg1 0x100000, bg0 0x100000, tmap_hi 0x80000, oki 0x40000

| Region | File | Offset | Bytes | Load | CRC32 | Line |
|---|---|---|---|---|---|---|
| maincpu | rspl00.bin | 0x000000 | 0x020000 | 16_BYTE | 40356b9d | 2681 |
| maincpu | rspu00.bin | 0x000001 | 0x020000 | 16_BYTE | 6635c668 | 2682 |
| audiocpu | rse3.bin | 0x000000 | 0x010000 | LOAD | 03c8fd17 | 2685 |
| sprite | rse4.bin | 0x000000 | 0x080000 | 16_BYTE | b857e411 | 2688 |
| sprite | rse5.bin | 0x000001 | 0x080000 | 16_BYTE | 7822d77a | 2689 |
| sprite | rse6.bin | 0x100000 | 0x080000 | 16_BYTE | 80215c52 | 2690 |
| sprite | rse7.bin | 0x100001 | 0x080000 | 16_BYTE | bd28bbdc | 2691 |
| fg1 | rse11.bin | 0x000000 | 0x080000 | 16_BYTE | 8a0c572f | 2694 |
| fg1 | rse10.bin | 0x000001 | 0x080000 | 16_BYTE | 139d5947 | 2695 |
| fg0 | rse15.bin | 0x000000 | 0x080000 | 16_BYTE | d188134d | 2698 |
| fg0 | rse14.bin | 0x000001 | 0x080000 | 16_BYTE | 0ef637a7 | 2699 |
| bg1 | rse17.bin | 0x000000 | 0x080000 | 16_BYTE | 7ff0f3c7 | 2702 |
| bg1 | rse16.bin | 0x000001 | 0x080000 | 16_BYTE | c176c8bc | 2703 |
| bg0 | rse21.bin | 0x000000 | 0x080000 | 16_BYTE | 2ea665af | 2706 |
| bg0 | rse20.bin | 0x000001 | 0x080000 | 16_BYTE | ef93e3ac | 2707 |
| tmap_hi | rse12.bin | 0x000000 | 0x020000 | LOAD | fadbf947 | 2710 |
| tmap_hi | rse13.bin | 0x020000 | 0x020000 | LOAD | 323d4df6 | 2711 |
| tmap_hi | rse18.bin | 0x040000 | 0x020000 | LOAD | e00c9171 | 2712 |
| tmap_hi | rse19.bin | 0x060000 | 0x020000 | LOAD | d214d1d0 | 2713 |
| oki | rse1.bin | 0x000000 | 0x020000 | LOAD | 0291166f | 2716 |
| oki | rse2.bin | 0x020000 | 0x020000 | LOAD | 5a26ee72 | 2717 |

File and region bytes 7232 KB.

Clone `rsharka` (2720-2759), 14 files differ (sprites, fg0 and tmap_hi
part 2 are identical in content; all names differ):

| Region | File | Offset | Bytes | Load | CRC32 | Line |
|---|---|---|---|---|---|---|
| maincpu | 9.1 | 0x000000 | 0x020000 | 16_BYTE | dafa38df | 2722 |
| maincpu | 8.2 | 0x000001 | 0x020000 | 16_BYTE | 31bd7b90 | 2723 |
| audiocpu | 1.15 | 0x000000 | 0x010000 | LOAD | 8be49bc1 | 2726 |
| fg1 | 11.13 | 0x000000 | 0x080000 | 16_BYTE | b5912b55 | 2735 |
| fg1 | 10.12 | 0x000001 | 0x080000 | 16_BYTE | 345456af | 2736 |
| bg1 | 17.7 | 0x000000 | 0x080000 | 16_BYTE | f47e164c | 2743 |
| bg1 | 16.6 | 0x000001 | 0x080000 | 16_BYTE | 52fae286 | 2744 |
| bg0 | 21.4 | 0x000000 | 0x080000 | 16_BYTE | 0b7b6cc4 | 2747 |
| bg0 | 20.3 | 0x000001 | 0x080000 | 16_BYTE | 31f218bf | 2748 |
| tmap_hi | 12.14 | 0x000000 | 0x020000 | LOAD | d5cab49c | 2751 |
| tmap_hi | 18.8 | 0x040000 | 0x020000 | LOAD | 5e0091a1 | 2753 |
| tmap_hi | 19.5 | 0x060000 | 0x020000 | LOAD | e5ae7112 | 2754 |
| oki | 2.16 | 0x000000 | 0x020000 | LOAD | dbe5632b | 2757 |
| oki | 3.17 | 0x020000 | 0x020000 | LOAD | 0dcd3ffb | 2758 |

#### `popbingo` (dooyong.cpp:2801-2823)

Regions: maincpu 0x40000, audiocpu 0x10000, sprite 0x100000, bg0 0x100000, bg1 0x100000, oki 0x40000

| Region | File | Offset | Bytes | Load | CRC32 | Line |
|---|---|---|---|---|---|---|
| maincpu | rom2.3f | 0x000000 | 0x020000 | 16_BYTE | b24513c6 | 2803 |
| maincpu | rom3.3e | 0x000001 | 0x020000 | 16_BYTE | 48070081 | 2804 |
| audiocpu | rom1.3p | 0x000000 | 0x010000 | LOAD | 46e8d2c4 | 2807 |
| sprite | rom5.9m | 0x000000 | 0x080000 | 16_BYTE | e8d73e07 | 2810 |
| sprite | rom6.9l | 0x000001 | 0x080000 | 16_BYTE | c3db3975 | 2811 |
| bg0 | rom10.9a | 0x000000 | 0x080000 | 16_BYTE | 135ab90a | 2814 |
| bg0 | rom9.9c | 0x000001 | 0x080000 | 16_BYTE | c9d90007 | 2815 |
| bg1 | rom7.9h | 0x000000 | 0x080000 | 16_BYTE | b2b4c13b | 2818 |
| bg1 | rom8.9e | 0x000001 | 0x080000 | 16_BYTE | 66c4b00f | 2819 |
| oki | rom4.4r | 0x000000 | 0x020000 | LOAD | 0fdee034 | 2822 |

File bytes 3520 KB; region bytes 3648 KB. The PCB layout shows an
unpopulated socket next to ROM4 (2770, 2797).

## 14. Consolidated uncertainty list

### 14.1 TODO(MAME), stated in the driver

| ID | Item | Lines |
|---|---|---|
| T1 | YM2203 port A is read constantly and stored; function unknown (MAME returns 0) | 24-25, 1452-1455, 1475, 1480 |
| T2 | bluehawk/flytiger main programs write a fixed sequence to 0x0000-0x001F. M0: flytiger pattern is a block fill plus field stores on a zero base pointer (3.8); ignore | 26-29 |
| T3 | rshark/superx write 0x0000 to I/O +0x18/+0x1A regularly. M0: once per frame on rshark, superx and popbingo | 30-34 |
| T4 | Sound programs write 0x00 to 0x0003 and 0xF7 to 0x0004. M0: about 3 times per frame in all five YM2151 games | 35-38 |
| T5 | Primella cocktail mode and buttons 2/3 | 39-41 |
| T6 | Pop Bingo unknown reads/writes; 0x0DC000 "registers of some kind?" | 42-43, 970, 976 |
| T7 | YM2203 IRQs OR-ed as a workaround; real routing untraced | 47-67, 1467-1479 |
| T8 | Sound CPU at 8 MHz as a hack (gulfstrm only in current code) | 58-60, 1540 |
| T9 | Music tempo and pitch depend on "(unknown) YM clocks" | 58 |
| T10 | vblank time "not accurate"; screen geometry not from `set_raw` | 1513 etc. |
| T11 | Sprite priority "seems a bit strange" | 536-537, 717-718 |
| T12 | 68000 IRQ6 at line 120 "timer irq?" | 1727 |
| T13 | Unknown ctrl bits: lastday bit 3; pollux bits 2 and 4; flytiger bits 1-2; primella bit 5; 68000 bit 5 | 428, 458-460, 486, 475, 333 |
| T14 | ROM tilemap registers 2, 5, 7 unknown. M0: each holds one constant per game in attract mode (7.2) | tm.cpp:98-101 |
| T15 | Primella 0xD000-0xD3FF RAM purpose | 906 |
| T16 | flytiger SYSTEM bit 6 vblank for colour cycling, disabled | 1255 |
| T17 | lastday tilt bit "maybe" | 1197 |
| T18 | gundl94 extra ROMs of unknown purpose. M0 (cheap look only): cpu2 starts with the same Z80 reset stub as flytiger and bluehawk (`F3 ED 56 C3 3E 00`) and shares a few 32-byte runs with the flytiger main ROM; gfx4 matches nothing in the ten sets. Not identified; not needed | 2507-2513 |
| T19 | polluxn fg0_tmap BAD_DUMP. M0: the 13 differing bytes are in the unused part of the map ROM (7.2), so they cannot affect the picture | 2242 |
| T20 | Unverified clocks: gulfstrm (all), bluehawk (all) | 1536-1565, 1606-1644 |

### 14.2 OPEN, raised by this spec

| ID | Item | Section |
|---|---|---|
| O1 | lastday/gulfstrm/pollux map ROMs are 4x larger than the 16-bit X position can address. **Answered (M0):** the extra 3/4 is 0xFFFF fill or stale program code; register 2 is constant | 7.2 |
| O2 | gulfstrm YM clock value vs comment; pollux 1.5 MHz not a divisor of 16 MHz | 2 |
| O3 | Horizontal total: 512 (MAME) vs about 510 (PCB HSync figure); line count unknown | 5.3 |
| O4 | Sprite code height masking `code &= ~height` | 10.1 |
| O5 | Sprite-order rule (first processed wins, hidden pixels still block) is a MAME drawing artefact; real hardware may differ | 10.3 |
| O6 | Per-line sprite limits of the real hardware (MAME draws all 128 or 256) | 10 |
| O7 | Sprites without a Y-shift extension cannot wrap at the top in MAME | 10.1 |
| O8 | Bluehawk's constant +6 sprite Y offset | 10.1 |
| O9 | Which map format (reg 6 bit 5) each game actually selects. **Answered (M0):** per-layer table in 7.3; bluehawk fg1 uses format A | 7.3 |
| O10 | Whether any game writes scroll or control registers mid-frame (MAME renders once per frame unless partial updates are forced). **Answered (M0):** yes, pollux and all 68000 games every frame; the RTL must latch at vblank for MAME parity; real-board behaviour is research item R12 | 5.4 |
| O11 | Whether the real boards latch the tilemap scroll registers at vblank (MAME parity requires it, 5.4) | 5.4 |
