#!/bin/sh
# test of the CD savestate logic (rtl/savestates/ss_cd.sv)
cd "$(dirname "$0")"
verilator --binary --timing -j 4 -Wno-fatal -Wno-WIDTH -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN -Wno-INITIALDLY \
	--top-module tb -o tb_ss_cd tb_ss_cd.sv ../../rtl/savestates/ss_cd.sv && ./obj_dir/tb_ss_cd
