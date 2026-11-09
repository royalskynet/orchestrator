#!/usr/bin/env bash
# WO-F5：快照上線前入列的舊單（TASK= 指可變原檔）在 wt_setup 之前就要補快照。
# 否則 TASK0= 記的是原檔路徑，runner 被殺後還原指回原檔，原檔一改第二輪就讀到新內容。
# 做法：手工造舊格式 pending job（TASK= 指 $T/legacy.md）→ 第一輪假 dc 存下 running job 就結束
# → 放回 running/ 模擬被殺 → 改掉原檔 → 第二輪斷言 dc 收到的還是原內容、cwd 存在。
set -u
. "$(dirname "$0")/env.sh"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
export DCQ_HOME="$T/q"; mkdir -p "$T/bin"
export DC_BIN="$T/bin" PATH="$T/bin:$PATH"
export DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"
export DCQ_FREE_ROUNDS=1 DCQ_POOL_PAID="" DCQ_POOL_TAIL="" DCQ_ORDER=default
export TRACE="$T/trace" SAVE="$T/saved.job"; : > "$TRACE"

cat > "$T/bin/dc" <<'EOF'
#!/usr/bin/env bash
cwd="$2"
echo "CWD $cwd $([ -d "$cwd" ] && echo exists || echo missing)" >> "$TRACE"
[ -f "$1" ] && grep -q '只是測試' "$1" || exit 2
grep -q 'ORIGINAL-CONTENT' "$1" || { echo 'TASK drifted' >> "$TRACE"; exit 2; }
echo 'TASK valid' >> "$TRACE"
if [ ! -e "$SAVE" ]; then
  cp "$DCQ_HOME"/running/*.job "$SAVE"
  id="$(basename "$cwd")"
  cp -R "$DCQ_HOME/.src/$id" "$SAVE.src"
fi
exit 0
EOF
chmod +x "$T/bin/dc"
for g in deep-lint wo-verify; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$g"; chmod +x "$T/bin/$g"; done

git init -q "$T/repo"; git -C "$T/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf '# a\n只是測試\nORIGINAL-CONTENT\n' > "$T/legacy.md"
mkdir -p "$DCQ_HOME/pending"
printf 'TASK=%s\nORIG_TASK=%s\nCWD=%s\nTIER=mid\nORDER=default\n' "$T/legacy.md" "$T/legacy.md" "$T/repo" > "$DCQ_HOME/pending/legacy.job"
DCQ_MODELS="m1" DCQ_MODEL_MAX=1 "$REPO/bin/dcq" run -j 1 >"$T/run1.out" 2>&1

fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
chk "第一輪在 worktree 跑" "$(grep -c "^CWD $DCQ_HOME/.wt/" "$TRACE")" "1"
chk "worktree job 的 TASK0= 指快照" "$(grep -c "^TASK0=$DCQ_HOME/.src/" "$SAVE" 2>/dev/null)" "1"

# 模擬被殺：job 放回 running/（TASK 記的是它跑當時的值），原檔被改掉
# 被殺 = 來不及收尾：worktree／鎖／done 檔都還在
# 造景失敗必須讓測試紅；原檔未改成功時，第二輪讀到原內容也可能假綠。
setup() { "$@" || { echo "FAIL 造景失敗：$*" | tee "$T/setup.err"; fail=1; return 1; }; }
setup cp "$SAVE" "$DCQ_HOME/running/legacy.job"
# 鎖目錄名同 hash12（bin/dcq:454）：算不出非 12 字元就當造景失敗，不靠空路徑混過去
H="$(printf '%s' "$T/repo" | shasum | cut -c1-12)"
case "$H" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) echo "FAIL 造景失敗：cwdlock hash '$H' 不是 12 字元" | tee "$T/setup.err"; fail=1 ;;
esac
H="${H:-x}"
setup mkdir -p "$DCQ_HOME/.cwdlock/$H"
rm -f "$DCQ_HOME"/done/*.job
# 快照放回（要 merge 內容，不是把目錄 cp 進去）
setup mkdir -p "$DCQ_HOME/.src/legacy"
setup sh -c "cp -R '$SAVE.src/.' '$DCQ_HOME/.src/legacy/'"
write_original() {
  printf '# a\n只是測試\nCHANGED-CONTENT\n' > "$T/legacy.md"
}
setup write_original
# 改寫後必須確認造景成立，才進第二輪。
if ! grep -q '^CHANGED-CONTENT$' "$T/legacy.md" || grep -q 'ORIGINAL-CONTENT' "$T/legacy.md"; then
  echo "FAIL 造景失敗：write_original 未改成 CHANGED-CONTENT" | tee -a "$T/setup.err"
  fail=1
fi
[ "$fail" = 0 ] || exit "$fail"
: > "$TRACE"
DCQ_MODELS="m1" DCQ_MODEL_MAX=1 "$REPO/bin/dcq" run -j 1 >"$T/run2.out" 2>&1
chk "第二輪 dc 拿到原內容" "$(grep -c '^TASK valid$' "$TRACE")" "1"
chk "第二輪 cwd 存在" "$(grep -c ' exists$' "$TRACE")" "1"

[ -n "${KEEP:-}" ] && cp -R "$T" /tmp/legkeep.$$ && echo "kept /tmp/legkeep.$$"
[ "$fail" = 0 ] || { echo "--- setup ---"; cat "$T/setup.err" 2>/dev/null; echo "--- run1 ---"; tail -20 "$T/run1.out"; echo "--- run2 ---"; tail -20 "$T/run2.out"; echo "--- saved ---"; cat "$SAVE"; echo "--- trace ---"; cat "$TRACE"; }
[ "$fail" = 0 ] && echo PASS
exit $fail
