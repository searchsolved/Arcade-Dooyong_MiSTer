# Dooyong simulation / oracle harness.
#
# M0 targets (MAME 0.288 on PATH, or MAME=...; ROM zips in ../roms):
#   make roms-check      CRC/SHA1 of all 25 sets vs the table generated from
#                        reference/mame/dooyong.cpp
#   make regions         rebuild every MAME region + SDRAM image (build/regions)
#   make mame-regions    dump regions from MAME for all 25 sets and compare
#                        byte for byte with `make regions`
#   make oracle          flytiger + bluehawk oracle captures (attract, flip)
#   make oracle-verify   Python renderer vs MAME on every captured frame
#   make oracle-extra    300 sampled frames of each other Z80 parent + verify
#                        (not part of the M0 gate; checks the shared model)
#   make survey          write-log runs of all 10 parents (O1/O9/O10 data)
#   make analyze         map ROM analysis (O1) + write-log summaries
#   make m0              everything above, in order
#
# M1 targets (Verilator; needs `make regions` and the oracle captures):
#   make m1-build        build the dy_video frame-replay harness
#   make m1-verify       RTL vs MAME on every flytiger/bluehawk capture (gate)
#   make m1-extra        RTL vs MAME on the lastday/gulfstrm/pollux/sadari/gundl94 samples
#   make m1-synth        synthetic scenes vs the Python renderer (gate)
#
# M2 targets:
#   make m2-build        build the dy_sys harness (48 MHz sim clock)
#   make m2-boot         flytiger + bluehawk from power-on through both MAME
#                        attract captures (8,800 / 9,000 frames, about 35 min
#                        each, run in parallel), compared with MAME (gate)
#   make m2-primella     sadari + gundl94 boot, images, RAM, sound streams, audio
#   make m2-soak         flytiger 20,000 frames, gate counters must stay 0
#
# M3 targets (sound; the dy_sys harness includes the sound CPU, jt51, jt6295):
#   make m3-wav          MAME WAVs of 7,300 frames (flytiger, bluehawk)
#   make m3              7,300 frames of each game (about 1 h, in parallel),
#                        register streams and mix level compared with MAME
#
# M4 targets (board: dy_board = dy_sys + dy_sdram, SDRAM model, ioctl download):
#   make m4-mra          generate the MRAs and prove each rebuilds sdram.bin
#   make m4-build        build the board harness (96 MHz, MAME parity timing)
#   make m4-boot         flytiger via the MRA stream + SDRAM, compared with MAME
#
# All MAME output lands in mame/out (gitignored). Every run starts from a
# wiped cfg/nvram directory (mame/run_mame.sh), so captures are reproducible
# from power-on.

PY      ?= python3
MAME    ?= mame
export MAME
OUT     := mame/out
RUN     := mame/run_mame.sh
ORACLE  := mame/dy_oracle.lua
ALLSETS := $(shell $(PY) -c "import sys; sys.path.insert(0,'../tools'); from romdefs import parse_driver; print(' '.join(parse_driver()))")
PARENTS := lastday gulfstrm pollux flytiger bluehawk sadari gundl94 superx rshark popbingo

# Capture plan (frame numbers = MAME frame notifier count, 60 Hz).
# flytiger attract loop is about 4,300 frames (boot 0-240, intro city,
# stage-1 boss intro, title 1,300-1,700, demo play 1,800-3,000, name entry,
# repeat); bluehawk demos start around frame 300.
FT_ATTRACT := 1-8800/8,2000-2599
BH_ATTRACT := 1-9000/8,600-1199
FLIP_FRAMES := 1-3000/10

EXTRA   := lastday gulfstrm pollux sadari gundl94

.PHONY: m4-mra m4-build m4-boot m3 m3-wav m3-wav-primella m2-primella m2-build m2-boot m2-soak m1-build m1-verify m1-extra m1-synth roms-check regions mame-regions oracle oracle-flytiger oracle-bluehawk \
        oracle-verify oracle-extra survey analyze m0 clean-out

roms-check:
	$(PY) ../tools/check_roms.py

regions:
	$(PY) ../tools/build_regions.py

mame-regions: regions
	@for s in $(ALLSETS); do \
	  DUMP_DIR=$(OUT)/regions/$$s $(RUN) $$s mame/dump_regions.lua -seconds_to_run 5 >/dev/null 2>&1 \
	    || echo "MAME failed on $$s"; \
	done
	$(PY) ../tools/compare_regions.py $(ALLSETS)

oracle: oracle-flytiger oracle-bluehawk

oracle-flytiger:
	rm -rf $(OUT)/flytiger_attract $(OUT)/flytiger_flip
	DUMP_DIR=$(OUT)/flytiger_attract DUMP_FRAMES=$(FT_ATTRACT) $(RUN) flytiger $(ORACLE)
	DUMP_DIR=$(OUT)/flytiger_flip DUMP_FRAMES=$(FLIP_FRAMES) FIELDS="DSWA:Flip Screen:0" \
	  $(RUN) flytiger $(ORACLE)

oracle-bluehawk:
	rm -rf $(OUT)/bluehawk_attract $(OUT)/bluehawk_flip
	DUMP_DIR=$(OUT)/bluehawk_attract DUMP_FRAMES=$(BH_ATTRACT) $(RUN) bluehawk $(ORACLE)
	DUMP_DIR=$(OUT)/bluehawk_flip DUMP_FRAMES=$(FLIP_FRAMES) FIELDS="DSWA:Flip Screen:0" \
	  $(RUN) bluehawk $(ORACLE)

oracle-verify:
	@rc=0; for r in flytiger_attract flytiger_flip bluehawk_attract bluehawk_flip; do \
	  echo "== $$r"; $(PY) oracle/compare_frames.py $(OUT)/$$r --quiet || rc=1; \
	done; exit $$rc

oracle-extra:
	@rc=0; for s in $(EXTRA); do \
	  rm -rf $(OUT)/extra_$$s; \
	  DUMP_DIR=$(OUT)/extra_$$s DUMP_FRAMES=30-9000/30 $(RUN) $$s $(ORACLE) >/dev/null 2>&1 \
	    || echo "MAME failed on $$s"; \
	  echo "== $$s"; $(PY) oracle/compare_frames.py $(OUT)/extra_$$s --quiet || rc=1; \
	done; exit $$rc

survey:
	@for s in $(PARENTS); do \
	  rm -rf $(OUT)/survey_$$s; \
	  DUMP_DIR=$(OUT)/survey_$$s TOTAL=12000 NO_SNAP=1 $(RUN) $$s $(ORACLE) >/dev/null 2>&1 \
	    || echo "MAME failed on $$s"; \
	done

analyze:
	$(PY) ../tools/analyze_maps.py
	$(PY) ../tools/analyze_writes.py $(wildcard $(OUT)/survey_*)
	$(PY) ../tools/oracle_coverage.py $(wildcard $(OUT)/flytiger_* $(OUT)/bluehawk_*)

m0: roms-check mame-regions oracle oracle-verify survey analyze

clean-out:
	rm -rf $(OUT) build

# ---------------------------------------------------------------- M1
VERILATOR ?= verilator
M1RTL := ../rtl/dy_pkg.sv ../rtl/dy_dpram.sv ../rtl/dy_layer_pass.sv ../rtl/dy_spr_z80.sv ../rtl/dy_video.sv
M1BIN := build/m1/obj_dir/Vdy_video
M1RUNS := $(OUT)/flytiger_attract $(OUT)/flytiger_flip $(OUT)/bluehawk_attract $(OUT)/bluehawk_flip

$(M1BIN): $(M1RTL) m1/tb_video.cpp
	$(VERILATOR) --cc --exe --build -O3 -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND \
	  --top-module dy_video --Mdir build/m1/obj_dir -j 0 \
	  -CFLAGS -O2 $(M1RTL) m1/tb_video.cpp

m1-build: $(M1BIN)

m1-verify: $(M1BIN)
	$(PY) m1/replay.py $(M1RUNS) --quiet

# primella family (sadari, gundl94) not in the M1 RTL yet
M1EXTRA := lastday gulfstrm pollux sadari gundl94
m1-extra: $(M1BIN)
	$(PY) m1/replay.py $(addprefix $(OUT)/extra_,$(M1EXTRA)) --quiet

m1-synth: $(M1BIN)
	$(PY) m1/make_scenes.py build/m1/scenes
	$(PY) m1/replay.py $(wildcard build/m1/scenes/*) --quiet

# ---------------------------------------------------------------- M2
# The simulation runs the system clock at 48 MHz (CPU /6, pixel 7,864,320 Hz
# from 48 MHz) with a ROM model of one read per 4 clocks, latency 5; the
# M1 budget numbers at 48 MHz (m1_findings 4) show this fits.
M2RTL := ../rtl/vendor/t80/T80s.v $(wildcard ../rtl/vendor/jt51/hdl/jt51*.v) \
  $(wildcard ../rtl/vendor/jt6295/hdl/*.v) $(M1RTL) ../rtl/dy_snd.sv ../rtl/dy_sys.sv
M2DIR ?= build/m2/obj_dir
M2BIN := $(M2DIR)/Vdy_sys

$(M2BIN): $(M2RTL) m2/tb_sys.cpp
	$(VERILATOR) --cc --exe --build -O3 -Wno-fatal -Wno-lint -Wno-style --x-assign fast --x-initial fast \
	  --top-module dy_sys --Mdir $(M2DIR) -j 0 \
	  -GCPU_DIV=6 -GCLK_HZ=48000000 -GPIX_NUM=786432 -GPIX_DEN=4800000 -I../rtl/vendor/jt51/hdl \
	  -CFLAGS -O2 $(M2RTL) m2/tb_sys.cpp

m2-build: $(M2BIN)

M2OUT := build/m2/gate

m2-boot: $(M2BIN)
	m2/run_boot.sh $(M2BIN) flytiger 3 8801 $(M2OUT)/flytiger $(OUT)/flytiger_attract & \
	m2/run_boot.sh $(M2BIN) bluehawk 4 9001 $(M2OUT)/bluehawk $(OUT)/bluehawk_attract & wait
	@tail -n 1 $(M2OUT)/flytiger/run.log $(M2OUT)/bluehawk/run.log
	$(PY) m2/compare.py $(M2OUT)/flytiger $(OUT)/flytiger_attract --quiet
	$(PY) m2/compare.py $(M2OUT)/bluehawk $(OUT)/bluehawk_attract --quiet

m2-soak: $(M2BIN)
	mkdir -p $(M2OUT)/soak && : > $(M2OUT)/soak/cap.txt
	$(M2BIN) +game=3 +sdram=build/regions/flytiger/sdram.bin +frames=20000 \
	  +cap=$(M2OUT)/soak/cap.txt +out=$(M2OUT)/soak | tail -n 1

# primella family (sadari 5, gundl94 6): boot through the oracle-extra runs
# (300 sampled frames of 9,000), sound streams logged; DSWB 0xFD = MAME
# default. About 1 h, both in parallel.
m2-primella: $(M2BIN)
	@for g in sadari:5 gundl94:6; do s=$${g%:*}; id=$${g#*:}; o=$(M2OUT)/$$s; \
	  rm -rf $$o && mkdir -p $$o; \
	  ls $(OUT)/extra_$$s/frames | sed 's/^0*//' | awk '{print $$1; print $$1-1}' | sort -n | uniq | awk '$$1>0' > $$o/cap.txt; \
	  $(M2BIN) +game=$$id +dswb=FD +sdram=build/regions/$$s/sdram.bin +frames=9001 +cap=$$o/cap.txt \
	    +out=$$o +snd=$$o/snd.txt +wav=$$o/audio.raw > $$o/run.log & \
	done; wait
	$(PY) m2/compare.py $(M2OUT)/sadari $(OUT)/extra_sadari --quiet
	$(PY) m2/compare.py $(M2OUT)/gundl94 $(OUT)/extra_gundl94 --quiet
	-$(PY) m3/compare_snd.py $(M2OUT)/sadari/snd.txt $(OUT)/extra_sadari --frames 9000
	-$(PY) m3/compare_snd.py $(M2OUT)/gundl94/snd.txt $(OUT)/extra_gundl94 --frames 9000
	$(PY) m3/compare_audio.py $(M2OUT)/sadari/audio.raw $(OUT)/m3wav_sadari.wav
	$(PY) m3/compare_audio.py $(M2OUT)/gundl94/audio.raw $(OUT)/m3wav_gundl94.wav

m3-wav-primella:
	@for s in sadari gundl94; do \
	  DUMP_DIR=$(OUT)/m3wav_$$s TOTAL=9000 NO_SNAP=1 DUMP_FRAMES=9000 \
	    $(RUN) $$s $(ORACLE) -wavwrite $(CURDIR)/$(OUT)/m3wav_$$s.wav -samplerate 48000 >/dev/null 2>&1; \
	done

# ---------------------------------------------------------------- M3
M3OUT := build/m3/gate
M3FRAMES := 7300

m3-wav:
	@for s in flytiger bluehawk; do \
	  DUMP_DIR=$(OUT)/m3wav_$$s TOTAL=$(M3FRAMES) NO_SNAP=1 DUMP_FRAMES=$(M3FRAMES) \
	    $(RUN) $$s $(ORACLE) -wavwrite $(CURDIR)/$(OUT)/m3wav_$$s.wav -samplerate 48000 >/dev/null 2>&1; \
	done

m3: $(M2BIN)
	mkdir -p $(M3OUT)/flytiger $(M3OUT)/bluehawk
	: > $(M3OUT)/none.txt
	$(M2BIN) +game=3 +sdram=build/regions/flytiger/sdram.bin +frames=$(M3FRAMES) +cap=$(M3OUT)/none.txt \
	  +out=$(M3OUT)/flytiger +snd=$(M3OUT)/flytiger/snd.txt +wav=$(M3OUT)/flytiger/audio.raw > $(M3OUT)/flytiger/run.log & \
	$(M2BIN) +game=4 +sdram=build/regions/bluehawk/sdram.bin +frames=$(M3FRAMES) +cap=$(M3OUT)/none.txt \
	  +out=$(M3OUT)/bluehawk +snd=$(M3OUT)/bluehawk/snd.txt +wav=$(M3OUT)/bluehawk/audio.raw > $(M3OUT)/bluehawk/run.log & wait
	-$(PY) m3/compare_snd.py $(M3OUT)/flytiger/snd.txt $(OUT)/flytiger_attract --frames $(M3FRAMES)
	-$(PY) m3/compare_snd.py $(M3OUT)/bluehawk/snd.txt $(OUT)/bluehawk_attract --frames $(M3FRAMES)
	$(PY) m3/compare_audio.py $(M3OUT)/flytiger/audio.raw $(OUT)/m3wav_flytiger.wav
	$(PY) m3/compare_audio.py $(M3OUT)/bluehawk/audio.raw $(OUT)/m3wav_bluehawk.wav

# ---------------------------------------------------------------- M4
M4RTL := $(M2RTL) ../rtl/dy_sdram.sv ../rtl/dy_board.sv m4/sdram_model.sv m4/tb_board.sv
M4DIR ?= build/m4/obj_dir
M4BIN := $(M4DIR)/Vtb_board

m4-mra:
	$(PY) ../tools/make_mra.py

$(M4BIN): $(M4RTL) m4/tb_board.cpp
	$(VERILATOR) --cc --exe --build -O3 -Wno-fatal -Wno-lint -Wno-style --x-assign fast --x-initial fast \
	  --top-module tb_board --Mdir $(M4DIR) -j 0 -I../rtl/vendor/jt51/hdl $(M4GEN) \
	  -CFLAGS -O2 $(M4RTL) m4/tb_board.cpp

m4-build: $(M4BIN)

m4-boot: $(M4BIN)
	m2/run_boot.sh $(M4BIN) flytiger 3 1201 build/m4/boot_flytiger $(OUT)/flytiger_attract
	@tail -n 1 build/m4/boot_flytiger/run.log
	$(PY) m2/compare.py build/m4/boot_flytiger $(OUT)/flytiger_attract --quiet
