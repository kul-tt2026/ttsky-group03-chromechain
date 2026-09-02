#!/usr/bin/env bash
# Formal equivalence per module (section 6b). For every module whose port list is
# unchanged, build a yosys miter between the baseline and candidate versions and prove
# equivalence with equiv_simple + equiv_induct. Prints PROVEN / UNPROVEN / PORTS-DIFFER
# per module. Modules that include ckpt_defs.vh are read with each tree's own header.
#   usage: ./formal.sh [base_src] [cand_src] [module ...]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="${1:-$HERE/base_src}"
CAND="${2:-$HERE/../src}"
shift 2 2>/dev/null || true
ALL="tt_um_kul_chromechain cc_top top_fsm blob_loader w1_rom_final4 ckpt_block \
bitplane_buffer popcount active_pixel_scan l1_horner_acc l1_horner_cnt l1_acc_shadow \
l1_acc_shadow_cg checkpoint_ctrl requant_rom_x4 l2_weight_rom_x4 config_latch \
requant_unit l2_mac_x4 max2_node exit_tree_2stage"
MODS="${*:-$ALL}"
mkdir -p "$HERE/out/formal"
# Modules that instantiate other modules need those too; give each miter the whole tree
# and select the module under test as top of each side.
bf=""; cf=""
for m in $ALL; do bf="$bf $BASE/$m.v"; cf="$cf $CAND/$m.v"; done
rc=0
for m in $MODS; do
  log="$HERE/out/formal/$m.log"
  yosys -q -l "$log" -p "
read_verilog -DSYNTHESIS -I $BASE $bf
hierarchy -top $m
proc -norom
flatten
opt_clean
rename -top gold
design -stash gold
read_verilog -DSYNTHESIS -I $CAND $cf
hierarchy -top $m
proc -norom
flatten
opt_clean
rename -top gate
design -stash gate
design -copy-from gold -as gold gold
design -copy-from gate -as gate gate
equiv_make gold gate equiv
hierarchy -top equiv
async2sync
equiv_simple -seq 4
equiv_induct -seq 4
equiv_status -assert
" >/dev/null 2>&1
  st=$?
  if [ $st -eq 0 ] && grep -q "Equivalence successfully proven" "$log"; then
    echo "PROVEN         $m"
  elif grep -qiE "port|mismatch.*ports|Can't match" "$log" && grep -qiE "ports" "$log"; then
    echo "PORTS-DIFFER   $m   (see out/formal/$m.log)"; rc=1
  else
    u=$(grep -oE "Found [0-9]+ unproven" "$log" | head -1)
    echo "UNPROVEN       $m   ${u:-error}   (see out/formal/$m.log)"; rc=1
  fi
done
exit $rc
