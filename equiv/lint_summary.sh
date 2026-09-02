#!/usr/bin/env bash
# Reduce a verilator lint log to "CLASS file message" lines with line numbers and paths
# stripped, so two trees can be compared with diff regardless of line drift.
#   usage: ./lint_summary.sh <lint.log>
grep -E '^%(Warning|Error)' "${1:?log}" \
 | sed -E 's#^%(Warning|Error)-([A-Z0-9]+): [^ ]*/([^/:]+):[0-9]+:[0-9]+: #\2 \3 #' \
 | sort
