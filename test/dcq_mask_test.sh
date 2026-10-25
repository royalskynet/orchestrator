#!/usr/bin/env bash
# dcq .out 遮罩：HOME 底下沒有 ~/.claude/tools（雲端 clone 情境）也要遮掉憑證（2026-10-24，Grok 雲端 .out 留原文）。
# 假 dc 印一把假 key，跑完檢查 .out 只剩遮罩標記。不打上游。
set -u
. "$(dirname "$0")/env.sh"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME" "$T/bin" "$T/w"
export DCQ_HOME="$T/q" DC_BIN="$T/bin" PATH="$T/bin:$PATH"
export DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1 DCQ_POOLSYNC=0
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"
export DCQ_FREE_ROUNDS=1 DCQ_POOL_PAID="" DCQ_POOL_TAIL="" DCQ_ORDER=default
unset DCQ_MASK
# 假 key 用拼接產生，檔案本身不含 key 樣字串
export FAKEKEY="sk-or-v1-$(printf 'a1b2c3d4%.0s' 1 2 3 4)"
printf '#!/usr/bin/env bash\necho "OPENROUTER_API_KEY=$FAKEKEY"\necho "raw $FAKEKEY"\nexit 0\n' > "$T/bin/dc"
for g in deep-lint wo-verify; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$g"; done
chmod +x "$T/bin/"*
echo '# m' > "$T/m.md"
fail=0
for mode in node perl; do
[ "$mode" = perl ] && export DCQ_NODE_BIN=no-such-node
echo "== $mode"
id="$("$REPO/bin/dcq" add "$T/m.md" "$T/w" easy 2>/dev/null)"
DCQ_MODELS="m1" "$REPO/bin/dcq" run -j 1 >"$T/run.out" 2>&1
outs="$(ls "$DCQ_HOME"/logs/"$id".*.out 2>/dev/null)"
[ -n "$outs" ] || { echo "FAIL 沒有 .out"; fail=1; }
if [ -n "$outs" ] && grep -q "$FAKEKEY" $outs; then echo "FAIL .out 留著原文 key"; fail=1; else echo "PASS .out 沒有原文 key"; fi
if [ -n "$outs" ] && grep -q 'MASKED' $outs; then echo "PASS .out 有遮罩標記"; else echo "FAIL .out 沒有遮罩標記"; fail=1; fi
if grep -q '遮罩失敗' "$T/run.out"; then echo "FAIL 遮罩失敗警告：$(grep 遮罩失敗 "$T/run.out")"; fail=1; else echo "PASS 沒有遮罩失敗警告"; fi
[ "$fail" = 0 ] || { echo "--- run.out ---"; cat "$T/run.out"; }
done
unset DCQ_NODE_BIN
# 兩版規則一致：同一份 fixture，node 版與 perl 版輸出必須相同（字串用拼接，檔案本身不含 key／PEM／IP 樣）
P="$T/fx.txt"
{ echo "url https://u:p""w@host.example/x"; echo "OPENROUTER_API_KEY=$FAKEKEY"; echo "gh""p_$(printf 'Ab12%.0s' 1 2 3 4)";
  B="BEG""IN"; E="EN""D"; K="PRIV""ATE KEY"; echo "-----$B $K-----"; echo abc; echo "-----$E $K-----";
  echo "op Zx9$(printf 'Qw3e%.0s' 1 2 3 4 5 6 7)"; echo "h $(printf '0f%.0s' $(seq 20))";
  echo "nv nva""pi-$(printf 'abcdefgh%.0s' 1 2 3 4)";
  echo "mail a.b""@ex.com ip 8.8.""4.4 lan 192.168.""1.2 port 20128 v1.20128"; echo "correct""horsebatterystaple"; } > "$P"
node "$REPO/bin/mask-transcript.mjs" "$P" "$T/a" >/dev/null; perl "$REPO/bin/mask-transcript.pl" "$P" "$T/b" >/dev/null
if cmp -s "$T/a" "$T/b"; then echo "PASS node 版與 perl 版輸出相同（$(grep -o MASKED "$T/a" | wc -l | tr -d ' ') 處遮罩）"; else echo "FAIL 兩版輸出不同"; diff "$T/a" "$T/b"; fail=1; fi
grep -q '^nv <MASKED_KEY>$' "$T/a" && echo "PASS nvapi- 金鑰遮成 MASKED_KEY" || { echo "FAIL nvapi- 沒遮：$(grep '^nv ' "$T/a")"; fail=1; }
exit $fail
