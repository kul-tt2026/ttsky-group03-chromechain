#!/usr/bin/env bash
# Lint parity gate (section 6d). verilator --lint-only -Wall on one tree.
#   usage: ./run_lint.sh <src_dir>
set -u
SRC="${1:?src dir}"
SRCS="tt_um_kul_chromechain cc_top top_fsm blob_loader w1_rom_final4 ckpt_block \
bitplane_buffer popcount active_pixel_scan l1_horner_acc l1_horner_cnt l1_acc_shadow \
l1_acc_shadow_cg checkpoint_ctrl requant_rom_x4 l2_weight_rom_x4 config_latch \
requant_unit l2_mac_x4 max2_node exit_tree_2stage"
f=""; for m in $SRCS; do f="$f $SRC/$m.v"; done
verilator --lint-only -Wall -Wno-fatal -I"$SRC" --top-module tt_um_kul_chromechain $f 2>&1
