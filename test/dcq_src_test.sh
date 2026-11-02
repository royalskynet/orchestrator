#!/usr/bin/env bash
# dcq add --src pass-through（2026-11-02）：新單帶上前張單 cwd／分支／摘要，不重讀全部上下文。
set -u
. "$(dirname "$0")/env.sh"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DCQ_HOME="$T/q"; mkdir -p "$T/bin"
export DC_BIN="$T/bin" PATH="$T/bin:$PATH"
export DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1
export DC_ZEN_GATE="$T/zg"; export DCQ_FREE_ROUNDS=1 DCQ_POOL_PAID="" DCQ_POOL_TAIL="" DCQ_TRIAGE=0

fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
has() { case "$2" in *"$3"*) echo "PASS $1" ;; *) echo "FAIL $1（缺「$3」；實際：$2）"; fail=1 ;; esac; }
hasnt() { case "$2" in *"$3"*) echo "FAIL $1（不該有「$3」）"; fail=1 ;; *) echo "PASS $1" ;; esac; }

printf '#!/usr/bin/env bash\n' > "$T/bin/dc"
printf 'exit 0\n' >> "$T/bin/dc"
chmod +x "$T/bin/dc"
for g in deep-lint wo-verify; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$g"; chmod +x "$T/bin/$g"; done
printf '# 第一張\n## 驗收\n```bash\ntrue\n```\n' > "$T/a.md"
mkdir -p "$T/wd"

id1="$("$REPO/bin/dcq" add "$T/a.md" "$T/wd" easy 2>/dev/null)"
DCQ_MODELS=m1 DCQ_ALLOWED_FAILS=99 "$REPO/bin/dcq" run -j 1 >/dev/null 2>&1

id2="$("$REPO/bin/dcq" add --src "$id1" "$T/a.md" 2>/dev/null | tail -1)"
has "新單記 SRC" "$(cat "$DCQ_HOME"/pending/"$id2".job 2>/dev/null)" "SRC=$id1"
has "新單 CWD 推導跟前張" "$(cat "$DCQ_HOME"/pending/"$id2".job 2>/dev/null)" "CWD=$T/wd"
tcopy="$(sed -n 's/^TASK=//p' "$DCQ_HOME"/pending/"$id2".job)"
chk "task 指向副本" "$([ "$tcopy" != "$T/a.md" ] && echo yes)" "yes"
has "副本有續接段" "$(cat "$tcopy" 2>/dev/null)" "## 續前張單"
has "副本帶前張 id" "$(cat "$tcopy" 2>/dev/null)" "上張工單：$id1"
has "副本帶結果行" "$(cat "$tcopy" 2>/dev/null)" "result="
has "副本帶分支" "$(cat "$tcopy" 2>/dev/null)" "dcq/$id1"
has "副本保留原工單" "$(cat "$tcopy" 2>/dev/null)" "# 第一張"
has "副本帶驗收區塊" "$(cat "$tcopy" 2>/dev/null)" '## 驗收'

mkdir -p "$T/other"
id3="$("$REPO/bin/dcq" add "$T/a.md" "$T/other" easy --src "$id1" 2>/dev/null | tail -1)"
has "明給 cwd 優先" "$(cat "$DCQ_HOME"/pending/"$id3".job)" "CWD=$T/other"

before="$(ls "$DCQ_HOME"/pending | wc -l | tr -d ' ')"
o="$("$REPO/bin/dcq" add --src no-such "$T/a.md" "$T/wd" easy 2>&1)"; rc=$?
chk "--src 查無 rc（die=2，與其他用法錯誤一致）" "$rc" 2
has "--src 查無訊息" "$o" "查無工單 no-such"
chk "--src 查無不入列" "$(ls "$DCQ_HOME"/pending | wc -l | tr -d ' ')" "$before"

id4="$("$REPO/bin/dcq" add --src="$id1" "$T/a.md" "$T/wd" easy 2>/dev/null)"
has "--src= 寫法" "$(cat "$DCQ_HOME"/pending/"$id4".job 2>/dev/null)" "SRC=$id1"

id5="$("$REPO/bin/dcq" add "$T/a.md" "$T/wd" easy 2>/dev/null)"
chk "舊路徑 task 不複製" "$(sed -n 's/^TASK=//p' "$DCQ_HOME"/pending/"$id5".job)" "$T/a.md"
hasnt "舊路徑無 SRC" "$(cat "$DCQ_HOME"/pending/"$id5".job)" "SRC="

[ "$fail" = 0 ] && echo "PASS dcq_src" || echo "FAIL dcq_src"
exit "$fail"
