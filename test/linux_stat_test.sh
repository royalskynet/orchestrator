#!/usr/bin/env bash
# GNU stat（Linux）下 dcq 要能跑完一張工單（10-24 Grok 雲端 Linux 實測：開跑幾秒就
# `bin/dcq: line 829: $1: unbound variable`，工單卡在 running）。
# 根因：GNU `stat -f %m F` 是查檔案系統，stdout 先印多行 fs 資訊才失敗，`|| stat -c` 退路再補一行，
# mtime() 回傳垃圾 → `$(( t - gap ))` 在 set -u 下把 "ID:" 當變數 → watch_oc 的 subshell 死、零輸出。
# macOS 上用 coreutils 的 gstat 冒充 stat；本機 stat 已是 GNU 就直接用；兩者都沒有就 SKIP。
set -u
. "$(dirname "$0")/env.sh"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
if stat -c %Y / >/dev/null 2>&1; then :
elif command -v gstat >/dev/null 2>&1; then ln -s "$(command -v gstat)" "$T/bin/stat"
else echo "SKIP 沒有 GNU stat（brew install coreutils）"; exit 0; fi
export DCQ_HOME="$T/q" DC_BIN="$T/bin" PATH="$T/bin:$PATH"
export DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"
export DCQ_FREE_ROUNDS=1 DCQ_POOL_PAID="" DCQ_POOL_TAIL="" DCQ_ORDER=default

# 假 dc：睡過幾輪 POLL_S，讓 watch_oc 迴圈真的跑到 mtime()
printf '#!/usr/bin/env bash\nsleep 3; echo ok\nexit 0\n' > "$T/bin/dc"; chmod +x "$T/bin/dc"
for g in deep-lint wo-verify; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$g"; chmod +x "$T/bin/$g"; done

mkdir -p "$T/w"; git -C "$T/w" init -q
printf '# pong\n' > "$T/pong.md"
"$REPO/bin/dcq" add "$T/pong.md" "$T/w" >/dev/null || echo "add failed"
DCQ_MODELS="m1" DCQ_STALL_S=60 DCQ_SPIN_S=0 DCQ_ATTEMPT_MAX=60 \
  "$REPO/bin/dcq" run -j 1 >"$T/run.out" 2>&1; rc=$?

fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
chk "dcq run 結束碼 0" "$rc" "0"
"$REPO/bin/dcq" wait --timeout 5 >/dev/null 2>&1; chk "dcq wait 回 0" "$?" "0"
chk "沒有 unbound variable" "$(grep -c 'unbound variable' "$T/run.out")" "0"
chk "工單進 done" "$(ls "$DCQ_HOME/done" 2>/dev/null | grep -c '\.job$')" "1"
chk "不殘留 running" "$(ls "$DCQ_HOME/running" 2>/dev/null | wc -l | tr -d ' ')" "0"

# 防呆：watch_oc 再因任何原因零輸出，工單要判失敗（非 0）且不殘留 running。
# 用一支永遠吐 GNU `stat -f` 那種多行垃圾的假 stat 逼它崩。
T2="$T/crash"; mkdir -p "$T2/bin" "$T2/w"; git -C "$T2/w" init -q
cp "$T/bin/dc" "$T/bin/deep-lint" "$T/bin/wo-verify" "$T2/bin/"
printf '#!/bin/sh\nprintf "  File: x\\n    ID: y\\n"\n' > "$T2/bin/stat"; chmod +x "$T2/bin/stat"
DCQ_HOME="$T2/q" DC_BIN="$T2/bin" PATH="$T2/bin:$PATH" "$REPO/bin/dcq" add "$T/pong.md" "$T2/w" >/dev/null || echo "add2 failed"
DCQ_HOME="$T2/q" DC_BIN="$T2/bin" PATH="$T2/bin:$PATH" DCQ_MODELS="m1 m2" DCQ_STALL_S=60 DCQ_SPIN_S=0 DCQ_ATTEMPT_MAX=60 \
  timeout 60 "$REPO/bin/dcq" run -j 1 >"$T2/run.out" 2>&1
# dcq run 只負責跑完佇列；單張成敗看 dcq wait（0 全過／1 有失敗／124 逾時）
DCQ_HOME="$T2/q" "$REPO/bin/dcq" wait --timeout 5 >/dev/null 2>&1; rc2=$?
chk "崩潰時 dcq wait 回 1" "$rc2" "1"
chk "崩潰判 FATAL" "$(grep -c 'watch_oc 沒交出結果' "$T2/run.out")" "1"
chk "崩潰不換模型" "$(grep -c 'model=m2' "$T2/run.out")" "0"
chk "崩潰不殘留 running" "$(ls "$T2/q/running" 2>/dev/null | wc -l | tr -d ' ')" "0"
chk "崩潰工單進 failed" "$(ls "$T2/q/failed" 2>/dev/null | grep -c '\.job$')" "1"
[ "$fail" = 0 ] || { echo "--- run.out ---"; cat "$T/run.out"; echo "--- crash run.out ---"; cat "$T2/run.out"; }
[ "$fail" = 0 ] && echo PASS
exit $fail
