#!/bin/bash
# P0 静态 SASS 门（KANQ_PLAN.md）：热内核零 IMAD.HI + 无 local spill。
# 用法: sass_check.sh <binary> [kernel-substr]   （默认 mine_kernel）
set -euo pipefail
BIN=${1:?binary}; KS=${2:-mine_kernel}
CUDA_HOME=${CUDA_HOME:-/usr/local/cuda}
OBJDUMP=$(command -v cuobjdump || echo "$CUDA_HOME/bin/cuobjdump")
TMP=$(mktemp)
"$OBJDUMP" -sass "$BIN" > "$TMP.sass"
awk -v fn="$KS" '/Function : /{infn = index($0, fn) > 0} infn{print}' "$TMP.sass" > "$TMP.fn"
HI=$(grep -c "IMAD.HI" "$TMP.fn" || true)
SPILL=$(grep -cE "LDL|STL" "$TMP.fn" || true)
TOTAL=$(grep -cE "^ +/\*[0-9a-f]+\*/" "$TMP.fn" || true)
WIDE=$(grep -c "IMAD.WIDE" "$TMP.fn" || true)
echo "kernel=$KS instructions=$TOTAL IMAD.WIDE=$WIDE IMAD.HI=$HI LDL/STL(spill)=$SPILL"
rm -f "$TMP.sass" "$TMP.fn"
[ "$HI" -eq 0 ] || { echo "SASS CHECK: FAIL (IMAD.HI=$HI != 0)"; exit 1; }
[ "$SPILL" -eq 0 ] || { echo "SASS CHECK: FAIL (local spill)"; exit 1; }
echo "SASS CHECK: OK"
