#!/bin/bash
# delegate-guard 開關：on（刪狀態檔）／off（建狀態檔）／status（只讀）。
# 狀態檔存在＝off，不存在＝on。hook 每次呼叫重讀，切換立刻生效。
set -u
FILE="${DEGUARD_OFF_FILE:-$HOME/.claude/delegate-guard.off}"
case "${1:-status}" in
  on)   rm -f "$FILE"; echo "delegate-guard: on（狀態檔 $FILE 已移除，下一次工具呼叫即生效）" ;;
  off)  touch "$FILE"; echo "delegate-guard: off（已建 ${FILE}；再打 o delegate on 恢復）" ;;
  *)    if [ -e "$FILE" ]; then echo "delegate-guard: off"; else echo "delegate-guard: on"; fi ;;
esac
echo "log: ~/.claude/logs/delegate-guard.log"
