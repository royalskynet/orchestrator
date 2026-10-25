#!/usr/bin/env bash
# dcq watchdog：opencode 的工具子程序還在跑時，不判 stall／spin（10-21：模型自跑 164s 的 dcq_test，
# 沒輸出也沒改檔，被 spin／slow 殺掉重跑，WO-1/2 二十個嘗試全滅）。
# 假 dc 底下掛一支叫 opencode 的程序（複製 /bin/sh），它的子程序 sleep＝工具在跑。不打上游。
set -u
. "$(dirname "$0")/env.sh"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DCQ_HOME="$T/q"; mkdir -p "$T/bin" "$T/xb"
export DC_BIN="$T/bin" PATH="$T/bin:$PATH"
export DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"
export DCQ_FREE_ROUNDS=1 DCQ_POOL_PAID="" DCQ_POOL_TAIL="" DCQ_ORDER=default
export TRACE="$T/trace" XB="$T/xb"; : > "$TRACE"
cp /bin/sh "$XB/opencode"

# tool*：opencode 有子程序 8s（工具在跑）；idle*：dc 自己 sleep 8s（沒有工具）。兩者都沒輸出、不改檔。
cat > "$T/bin/dc" <<'EOF'
#!/usr/bin/env bash
n="$(basename "$1" .md)"
echo "IN $n $DC_FREE_MODEL" >> "$TRACE"
case "$n:$DC_FREE_MODEL" in
  tool*:m1) "$XB/opencode" -c 'sleep 8; :' ;;
  idle*:m1) sleep 8 ;;
esac
exit 0
EOF
chmod +x "$T/bin/dc"
for g in deep-lint wo-verify; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$g"; chmod +x "$T/bin/$g"; done

for n in tool1 idle1; do
  mkdir -p "$T/$n"; git -C "$T/$n" init -q
  printf '# %s\n' "$n" > "$T/$n.md"; "$REPO/bin/dcq" add "$T/$n.md" "$T/$n" >/dev/null || echo "add failed: $n"
done
DCQ_MODELS="m1 m2" DCQ_STALL_S=3 DCQ_SPIN_S=3 DCQ_ATTEMPT_MAX=60 DCQ_ALLOWED_FAILS=99 \
  "$REPO/bin/dcq" run -j 2 >"$T/run.out" 2>&1

fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
chk "工具在跑不判 stall／spin（tool1 只跑 m1）" "$(grep -c '^IN tool1' "$TRACE")" "1"
chk "沒工具的靜默照樣殺（idle1 換到 m2）" "$(grep -c '^IN idle1 m2' "$TRACE")" "1"
chk "watchdog 只殺 idle1" "$(grep -c 'watchdog: m1' "$T/run.out")" "1"
chk "watchdog 訊息印本次嘗試秒數" "$(grep -c '本次已跑 [0-9]*s，整張 [0-9]*s' "$T/run.out")" "1"
[ "$fail" = 0 ] || { echo "--- run.out ---"; cat "$T/run.out"; }
[ "$fail" = 0 ] && echo PASS
exit $fail
