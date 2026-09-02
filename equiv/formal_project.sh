#!/usr/bin/env bash
# Port-projected formal equivalence: when the candidate module gained output ports,
# demote those ports to plain wires in the candidate (yosys `delete -output`) and prove
# that every ORIGINAL port is driven identically. Internal net names stay intact, so
# equiv_induct has the same anchors as formal.sh.
#   usage: ./formal_project.sh <module> <base_src> <cand_src> <extra_port> [extra_port...]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
M="${1:?module}"; BASE="${2:?base}"; CAND="${3:?cand}"; shift 3
ALL="tt_um_kul_chromechain cc_top top_fsm blob_loader w1_rom_final4 ckpt_block \
bitplane_buffer popcount active_pixel_scan l1_horner_acc l1_horner_cnt l1_acc_shadow \
l1_acc_shadow_cg checkpoint_ctrl requant_rom_x4 l2_weight_rom_x4 config_latch \
requant_unit l2_mac_x4 max2_node exit_tree_2stage"
bf=""; cf=""; for m in $ALL; do bf="$bf $BASE/$m.v"; cf="$cf $CAND/$m.v"; done
demote=""; for p in "$@"; do demote="$demote
delete -output w:$p"; done
mkdir -p "$HERE/out/formal"
log="$HERE/out/formal/${M}_projected.log"
yosys -q -l "$log" -p "
read_verilog -DSYNTHESIS -I $BASE $bf
hierarchy -top $M
proc -norom
flatten
opt_clean
rename -top gold
design -stash gold
read_verilog -DSYNTHESIS -I $CAND $cf
hierarchy -top $M
proc -norom
flatten
$demote
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
if [ $? -eq 0 ] && grep -q "Equivalence successfully proven" "$log"; then
  echo "PROVEN (candidate ports $* demoted; all baseline ports equivalent)   $M"
else
  echo "UNPROVEN   $M   $(grep -oE 'Found [0-9]+ unproven' "$log" | head -1)   (see $log)"; exit 1
fi
