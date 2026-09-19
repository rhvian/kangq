#!/bin/bash
# KanQ 守护运行：矿工退出（矿池断连 / 15 s 无 job / 异常）后自动重启，日志追加到 kanq.log。
#   ./run.sh --wallet qz... --worker rig01 [--device 0] [其它 kanq 参数]
# 环境变量：
#   KANQ_RESTART        auto（默认）= 自动重启；0 = 只跑一次
#   KANQ_RESTART_DELAY  重启间隔秒数，默认 5
#   KANQ_LOG            日志文件，默认 ./kanq.log（设为 - 只打到终端）
# 停止：touch STOP（下次退出不再拉起），或直接 kill 矿工进程后守护会在看到 STOP 时结束。
set -u
cd "$(dirname "$0")"
BIN=./build/kanq
[ -x "$BIN" ] || { echo "未找到 $BIN，先 ./build.sh" >&2; exit 1; }
LOG="${KANQ_LOG:-./kanq.log}"
DELAY="${KANQ_RESTART_DELAY:-5}"
rm -f STOP
n=0
while true; do
  n=$((n+1))
  if [ "$LOG" = "-" ]; then
    echo "=== [守护] 第 $n 次启动 $(date '+%F %T') ==="
    "$BIN" "$@"; rc=$?
    echo "=== [守护] 矿工退出 rc=$rc $(date '+%F %T') ==="
  else
    echo "=== [守护] 第 $n 次启动 $(date '+%F %T') ===" | tee -a "$LOG"
    "$BIN" "$@" 2>&1 | tee -a "$LOG"; rc=${PIPESTATUS[0]}
    echo "=== [守护] 矿工退出 rc=$rc $(date '+%F %T') ===" | tee -a "$LOG"
  fi
  [ "${KANQ_RESTART:-auto}" = "0" ] && exit $rc
  if [ -f STOP ]; then
    msg="=== [守护] 发现 STOP，结束 $(date '+%F %T') ==="
    [ "$LOG" = "-" ] && echo "$msg" || echo "$msg" | tee -a "$LOG"
    exit 0
  fi
  sleep "$DELAY"
done
