#!/bin/sh
# Savestate regression: run A saves at frame 5, run C never saves, run B loads that state at frame 3.
# A must match C (saving does not disturb the core) and B must match A after the save point,
# cycle by cycle: CPU reads and writes, PSG output and video frame hashes.
# Needs GHDL 4 (mcode or LLVM backend) and python3.
set -e
cd "$(dirname "$0")"
R=../rtl
GHDL=${GHDL:-ghdl}
F="--std=08 -frelaxed -fsynopsys -fexplicit --workdir=work -Pwork"
rm -rf work && mkdir work
python3 mk_sim_files.py
python3 mk_top_sim.py
python3 rom/asm.py rom/sstest.asm work/sstest.pce
$GHDL -a --std=08 -frelaxed --workdir=work --work=altera_mf altera_mf_stub.vhd altsyncram_sim.vhd 2>/dev/null
for f in $R/savestates/bus_savestates.vhd $R/savestates/savestates.vhd $R/dpram.vhd \
         $R/HUC6280/HUC6280_PKG.vhd $R/HUC6280/AddSubBCD.vhd $R/HUC6280/HUC6280_ALU.vhd $R/HUC6280/HUC6280_AG.vhd \
         $R/HUC6280/HUC6280_MC.vhd $R/HUC6280/HUC6280_CPU.vhd $R/HUC6280/psg.vhd $R/HUC6280/HUC6280.vhd \
         work/huc6270_sim.vhd $R/huc6260.vhd $R/huc6202.vhd $R/CEGen.vhd work/fifo_stubs.vhd \
         $R/cd/MSM5205.vhd $R/cd/SCSI.vhd $R/cd/cd.vhd stubs.vhd work/pce_top_sim.vhd tb.vhd; do
  $GHDL -a $F $f 2>&1 | grep -i "error" || true
done
$GHDL -e $F tb 2>&1 | grep -i "error" || true
RUN="$GHDL -r $F tb --ieee-asserts=disable -gROMFILE=work/sstest.pce"
$RUN -gMODE=1 -gF_EVENT=5 -gF_RUN=6 -gLOGFILE=work/a.log -gSTATEFILE=work/state.txt &
$RUN -gMODE=0 -gF_EVENT=5 -gF_RUN=6 -gLOGFILE=work/c.log &
wait
$RUN -gMODE=2 -gF_EVENT=3 -gF_RUN=6 -gLOGFILE=work/b.log -gSTATEFILE=work/state.txt
python3 compare.py ac work/a.log work/c.log
python3 compare.py ab work/a.log work/b.log work/state.txt
