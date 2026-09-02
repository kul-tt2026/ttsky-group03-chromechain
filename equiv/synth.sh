#!/usr/bin/env bash
# Synthesis parity gate (section 6c). Flattened yosys synth of one tree to sky130_fd_sc_hd,
# prints the liberty-priced stat. LIB defaults to the copy in the Chrome Chain project;
# any sky130_fd_sc_hd liberty works, the point is the SAME liberty for both trees.
# Low-power/isolation cells are excluded as the real flow excludes them.
#   usage: ./synth.sh <src_dir> <out.log>
set -u
SRC="${1:?src dir}"
LOG="${2:?log}"
LIB="${LIB:-$HOME/Documents/Projects/Chrome Chain/w1_rom_synthesis/lib/sky130_fd_sc_hd__tt_025C_1v80.lib}"
SRCS="tt_um_kul_chromechain cc_top top_fsm blob_loader w1_rom_final4 ckpt_block \
bitplane_buffer popcount active_pixel_scan l1_horner_acc l1_horner_cnt l1_acc_shadow \
l1_acc_shadow_cg checkpoint_ctrl requant_rom_x4 l2_weight_rom_x4 config_latch \
requant_unit l2_mac_x4 max2_node exit_tree_2stage"
f=""; for m in $SRCS; do f="$f $SRC/$m.v"; done
DU='-dont_use *lpflow* -dont_use *probe* -dont_use *_lp_* -dont_use *clkdlyinv* -dont_use *dlygate*'
yosys -q -l "$LOG" -p "
read_verilog -DSYNTHESIS -I $SRC $f
hierarchy -check -top tt_um_kul_chromechain
synth -top tt_um_kul_chromechain -flatten
dfflibmap -liberty \"$LIB\" $DU
abc -liberty \"$LIB\" $DU
opt_clean -purge
stat -liberty \"$LIB\"
" >/dev/null 2>&1
echo "== $SRC"
grep -E "^\s+[0-9]+ [0-9.E+]+ cells$|Chip area for module|of which used for sequential" "$LOG" | tail -3
grep -E "sky130_fd_sc_hd__(dfxtp|edfxtp|dfrtp|dlclkp|buf_|clkbuf|lpflow)" "$LOG" | tail -8
