#!/bin/bash
# KanQ 一键编译：产物 build/kanq（矿工）与 build/kanq-test（自检 + bench）。
# 环境变量：
#   NVCC   nvcc 路径（默认 PATH 里的 nvcc，找不到再试 /usr/local/cuda/bin/nvcc）
#   ARCH   目标架构，默认从 nvidia-smi 检测；多架构用 "sm_86 sm_89" 空格分隔
set -euo pipefail
cd "$(dirname "$0")"

NVCC="${NVCC:-$(command -v nvcc || true)}"
[ -z "$NVCC" ] && [ -x /usr/local/cuda/bin/nvcc ] && NVCC=/usr/local/cuda/bin/nvcc
[ -z "$NVCC" ] && { echo "找不到 nvcc：请安装 CUDA Toolkit 12.x 或设置 NVCC=/path/to/nvcc" >&2; exit 1; }

if [ -z "${ARCH:-}" ]; then
  cap=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d '. ')
  ARCH="sm_${cap:-89}"
fi
GENCODE=""
for a in $ARCH; do GENCODE="$GENCODE -gencode arch=compute_${a#sm_},code=$a"; done

mkdir -p build
echo "nvcc: $NVCC"; echo "arch: $ARCH"
t0=$(date +%s)
"$NVCC" -O3 -std=c++17 $GENCODE -o build/kanq      src/miner.cu     -lpthread
"$NVCC" -O3 -std=c++17 $GENCODE -o build/kanq-test src/kanq_test.cu
echo "done in $(( $(date +%s) - t0 )) s:"
ls -la build/kanq build/kanq-test
echo
echo "自检：./build/kanq-test fieldtest && ./build/kanq-test selftest vectors.txt && ./build/kanq-test pstest vectors.txt"
