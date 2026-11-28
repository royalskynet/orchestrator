---
name: deguard
description: delegate-guard 開關。使用者打 /deguard on|off|status 時用；on＝主 session 做量大低難度的機械活時先建議派 o，訊號強就直接改派 o-worker，off＝暫時關掉。
disable-model-invocation: true
---

# /deguard — delegate-guard 開關

狀態檔：`~/.claude/delegate-guard.off`。**存在＝off，不存在＝on**（hook 每次呼叫自己讀，切換立刻生效，不用重開 session）。

跑 `bash "${CLAUDE_PLUGIN_ROOT}/scripts/toggle.sh" <參數>`（等同 `o delegate <參數>`），把它的輸出一字不改貼給使用者。

- `on` → 刪狀態檔，回報「delegate-guard 已開」
- `off` → 建狀態檔，回報「delegate-guard 已關（這個 session 之後不再建議派或改派）」
- `status`（或沒參數）→ 只回報 on／off，不改

判準：本段工具呼叫 10 次（上下文 >100k 時 6 次）或任務打分命中 → 建議派；18 次（11 次）、同工具改 ≥10 檔、依賴升級／全套測試 → 直接改派（擋到派出為止，每段最多 3 次）。派給 o 的工單沒有 `## 驗收` 區塊會被擋；o 完工後照 hook 給的 `verify.mjs` 指令重驗。log 在 `~/.claude/logs/delegate-guard.log`。
