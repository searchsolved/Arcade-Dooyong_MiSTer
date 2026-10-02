# Releases

Released bitstreams and MRA files, in the MiSTer-devel arcade layout.

Copy `Arcade-Dooyong_YYYYMMDD.rbf` to `/media/fat/_Arcade/cores/`, the
MRA files to `/media/fat/_Arcade/`, and the ROM sets (MAME 0.288/0.289
naming) to `/media/fat/games/mame/`.

Alternative versions live in `_alternatives/_<game>/` and are copied to
`/media/fat/_Arcade/_alternatives/_<game>/`.

| File | md5 | Notes |
|------|-----|-------|
| `Arcade-Dooyong_20260930.rbf` | `29d749eb7c4166184e12fde7f8eeccdf` | First release: all ten games, 25 sets. |

Every released RBF passed, in order: frame replay against MAME for
every game (video pixel-exact), full-system boots against MAME from
power-on, a board-level simulation through the MRA stream and the SDRAM
model, a clean Quartus timing summary (every clock non-negative), and an
md5-verified deploy.
