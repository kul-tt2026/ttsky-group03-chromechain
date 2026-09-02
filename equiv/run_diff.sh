#!/usr/bin/env bash
# Differential simulation gate (section 6a). Builds tb_equiv against two RTL trees
# and diffs the per-cycle pin traces. Identical trace == equivalent at the TT pins.
#   usage: ./run_diff.sh [base_src_dir] [cand_src_dir] [out_dir]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="${1:-$HERE/base_src}"
CAND="${2:-$HERE/../src}"
OUT="${3:-$HERE/out}"
mkdir -p "$OUT"

SRCS="tt_um_kul_chromechain cc_top top_fsm blob_loader w1_rom_final4 ckpt_block \
bitplane_buffer popcount active_pixel_scan l1_horner_acc l1_horner_cnt l1_acc_shadow \
l1_acc_shadow_cg checkpoint_ctrl requant_rom_x4 l2_weight_rom_x4 config_latch \
requant_unit l2_mac_x4 max2_node exit_tree_2stage"

build () {  # $1 = src dir, $2 = trace name
  local f=""; for m in $SRCS; do f="$f $1/$m.v"; done
  iverilog -g2005 -I "$1" -o "$OUT/eq_$2.vvp" -s tb_equiv "$HERE/tb_equiv.v" $f || return 1
  ( cd "$OUT" && vvp "eq_$2.vvp" +trace="$2" | tail -2 )
}

build "$BASE" base.txt || { echo "BASE BUILD FAILED"; exit 2; }
build "$CAND" cand.txt || { echo "CAND BUILD FAILED"; exit 2; }
wc -l "$OUT/base.txt" "$OUT/cand.txt"
if diff -q "$OUT/base.txt" "$OUT/cand.txt" >/dev/null; then
  echo "EQUIVALENT"
else
  n=$(diff "$OUT/base.txt" "$OUT/cand.txt" | grep -c '^>')
  echo "DIFFERS - $n differing cycles - explain or revert"
  diff "$OUT/base.txt" "$OUT/cand.txt" | head -20
  exit 1
fi
