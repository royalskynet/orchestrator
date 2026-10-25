#!/usr/bin/env bash
# dcq I5：runner 跑到一半 bin/dcq 被改，不能繼續用舊碼收新單。
# 做法：測試用 bin/dcq 副本；假 dc 在第一張工單裡 touch 副本。期望：第一張跑完（不打斷）、
# runner 印重啟訊息並 exec 自己、第二張在新 process 跑完。不碰真佇列 ~/.dcq。
set -u
. "$(dirname "$0")/env.sh"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DCQ_HOME="$T/q"; mkdir -p "$T/bin"
cp "$REPO/bin/dcq" "$T/bin/dcq"
export DC_BIN="$T/bin" PATH="$T/bin:$PATH" DCQ_CATALOG="$REPO/catalog"
export DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"
export DCQ_FREE_ROUNDS=1 DCQ_POOL_PAID="" DCQ_POOL_TAIL="" DCQ_ORDER=default
export TRACE="$T/trace" SELF="$T/bin/dcq"; : > "$TRACE"

cat > "$T/bin/dc" <<'EOF2'
#!/usr/bin/env bash
n="$(basename "$1" .md)"
echo "IN $n" >> "$TRACE"
if [ "$n" = a1 ]; then sleep 1; touch -t 203001010000 "$SELF"; sleep 1; fi   # 跑到一半改 dcq
echo "OUT $n" >> "$TRACE"
exit 0
EOF2
chmod +x "$T/bin/dc"
for g in deep-lint wo-verify; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$g"; chmod +x "$T/bin/$g"; done

for n in a1 b2; do
  mkdir -p "$T/$n"; git -C "$T/$n" init -q
  printf '# %s\n' "$n" > "$T/$n.md"; "$T/bin/dcq" add "$T/$n.md" "$T/$n" >/dev/null || echo "add failed: $n"
done
DCQ_MODELS="m1" DCQ_STALL_S=30 DCQ_SPIN_S=0 timeout 120 "$T/bin/dcq" run -j 1 >"$T/run.out" 2>&1

fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
chk "偵測到更新並印重啟訊息" "$(grep -c 'bin/dcq 已更新，runner 以新版重啟' "$T/run.out")" "1"
chk "進行中的 a1 沒被打斷（有 OUT）" "$(grep -c '^OUT a1' "$TRACE")" "1"
chk "重啟後 b2 照樣跑完" "$(grep -c '^OUT b2' "$TRACE")" "1"
chk "兩張都進 done/" "$(ls "$T/q/done" 2>/dev/null | grep -c '\.job$')" "2"
chk "a1 只跑一次（沒重跑）" "$(grep -c '^IN a1' "$TRACE")" "1"
[ "$fail" = 0 ] || { echo "--- run.out ---"; cat "$T/run.out"; }
[ "$fail" = 0 ] && echo PASS
exit $fail
