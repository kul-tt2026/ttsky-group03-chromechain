#!/usr/bin/env bash
# Formal equivalence through a user-supplied wrapper. The wrapper instantiates the module
# under test and is compiled once against the baseline tree and once against the
# candidate; the two wrapped designs are then proven equivalent. Use it to (a) mask an
# output that is meant to differ, or (b) tie an input to a constant to prove
# equivalence under that condition.
#   usage: ./formal_wrap.sh <wrapper.v> <wrapper_top> <base_src> <cand_src>
#   BLACKLIST=<file> lists internal net names (one per line) that equiv_make must not
#   match, for nets that are meant to differ but are not visible at the wrapper ports.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WRAP="${1:?wrapper.v}"; TOP="${2:?top}"; BASE="${3:?base}"; CAND="${4:?cand}"
ALL="tt_um_kul_chromechain cc_top top_fsm blob_loader w1_rom_final4 ckpt_block \
bitplane_buffer popcount active_pixel_scan l1_horner_acc l1_horner_cnt l1_acc_shadow \
l1_acc_shadow_cg checkpoint_ctrl requant_rom_x4 l2_weight_rom_x4 config_latch \
requant_unit l2_mac_x4 max2_node exit_tree_2stage"
bf=""; cf=""; for m in $ALL; do bf="$bf $BASE/$m.v"; cf="$cf $CAND/$m.v"; done
mkdir -p "$HERE/out/formal"
log="$HERE/out/formal/${TOP}_wrapped.log"
yosys -q -l "$log" -p "
read_verilog -DSYNTHESIS -I $BASE $bf $WRAP
hierarchy -top $TOP
proc -norom
flatten
opt_clean
rename -top gold
design -stash gold
read_verilog -DSYNTHESIS -I $CAND $cf $WRAP
hierarchy -top $TOP
proc -norom
flatten
opt_clean
rename -top gate
design -stash gate
design -copy-from gold -as gold gold
design -copy-from gate -as gate gate
equiv_make ${BLACKLIST:+-blacklist $BLACKLIST} gold gate equiv
hierarchy -top equiv
async2sync
equiv_simple -seq 4
equiv_induct -seq 4
equiv_status -assert
" >/dev/null 2>&1
if [ $? -eq 0 ] && grep -q "Equivalence successfully proven" "$log"; then
  echo "PROVEN (through $(basename "$WRAP"))   $TOP"
else
  echo "UNPROVEN   $TOP   $(grep -oE 'Found [0-9]+ unproven' "$log" | head -1)   (see $log)"; exit 1
fi
