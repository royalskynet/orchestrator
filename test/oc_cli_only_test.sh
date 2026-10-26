#!/usr/bin/env bash
# 鐵則（2026-10-26 使用者定）：opencode free 層（Zen 無斜線／opencode/*、opencode-go/*-free）只准經 opencode CLI
# （opencode run／opencode serve 本機客戶端）呼叫，禁止任何 API 直打推論端點。
# 這支掃 repo 程式碼：碰 opencode.ai/zen 的只准是 /models、/usage 這類不推論的清單端點；
# 出現 chat/completions、/messages、/responses 之類推論路徑就 fail。
set -u
cd "$(dirname "$0")/.."
fail=0
hits="$(grep -rnI -E 'opencode\.ai/zen' bin oc-probe/bin | grep -v -E '^[^:]+:[0-9]+:\s*#' | grep -v -E 'zen(/go)?/v1/(models|usage)' || true)"
if [ -n "$hits" ]; then echo "FAIL 有程式碼碰 opencode.ai/zen 的非清單端點："; echo "$hits" | sed 's/^/    /'; fail=1; else echo "PASS opencode.ai/zen 只用清單端點"; fi
inf="$(grep -rnI -E '(chat/completions|/v1/messages|/v1/responses)' bin oc-probe/bin | grep -v -E '^[^:]+:[0-9]+:\s*#' || true)"
if [ -n "$inf" ]; then echo "FAIL 有程式碼直打推論 API："; echo "$inf" | sed 's/^/    /'; fail=1; else echo "PASS 沒有直打推論 API"; fi
# dc 對 opencode free 模型只能走 opencode run（中途換執行器就要先過這道閘）
o="$(grep -n 'opencode free 模型只准經 opencode CLI' bin/dc || true)"
[ -n "$o" ] && echo "PASS dc 有 CLI-only 閘" || { echo "FAIL dc 缺 CLI-only 閘"; fail=1; }
exit $fail
