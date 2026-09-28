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
#   make m1-extra        RTL vs MAME on the lastday/gulfstrm/pollux samples
#   make m1-synth        synthetic scenes vs the Python renderer (gate)
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

.PHONY: m1-build m1-verify m1-extra m1-synth roms-check regions mame-regions oracle oracle-flytiger oracle-bluehawk \
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
M1EXTRA := lastday gulfstrm pollux
m1-extra: $(M1BIN)
	$(PY) m1/replay.py $(addprefix $(OUT)/extra_,$(M1EXTRA)) --quiet

m1-synth: $(M1BIN)
	$(PY) m1/make_scenes.py build/m1/scenes
	$(PY) m1/replay.py $(wildcard build/m1/scenes/*) --quiet
