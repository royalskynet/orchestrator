#!/usr/bin/env bash
# B2（WO-F）：入列即快照。派出後覆寫／截斷／刪掉來源檔，runner 讀到的仍是入列當下的內容；
# 快照或 job 檔 mv 失敗時才非 0，且 pending 不出現新 job。假 dc、假 mv，不打上游。
set -u
. "$(dirname "$0")/env.sh"
R="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)" || exit 1; [ -d "$T" ] || exit 1; cd "$T" || exit 1
trap '[ -n "$T" ] && [ -d "$T" ] && [ "$T" != "$R" ] && case "$T" in "${TMPDIR:-/tmp}"*|/tmp/*|/var/folders/*) rm -rf "$T" ;; esac' EXIT
T="$(cd "$T" && pwd -P)"
export DCQ_HOME="$T/q" DC_BIN="$T/bin" PATH="$T/bin:$PATH"
export DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1 DCQ_AUTORANK=0 DCQ_POOLSYNC=0 DCQ_GO_STATE="$T/none.json"
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json" DCQ_ORDER=default DCQ_FREE_ROUNDS=1
export DCQ_POOL_TAIL="" DCQ_POOL_PAID="" DCQ_POOL_ZEN="za"
unset DCQ_MODELS DCQ_PREFER DCQ_ALLOW_API
mkdir -p "$T/bin" "$T/w" "$T/seen"

fail=0
chk() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: got '$2' want '$3'"; fail=1; fi; }

# 假 dc：把第一隻參數（工單快照）複製到 SEEN 留證
write_dc() {
  cat > "$T/bin/dc" <<'EOF'
#!/usr/bin/env bash
cp "$1" "$SEEN/$(basename "$1" .md).seen"
exit 0
EOF
  chmod +x "$T/bin/dc"
}
write_dc
for g in deep-lint wo-verify; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$g"; chmod +x "$T/bin/$g"; done
export SEEN="$T/seen"

# 三種來源變動：覆寫成垃圾、截斷、刪除；runner 讀到的必須等於入列當下
for c in overwrite truncate delete; do
  orig="$T/$c.md"
  printf '# %s\n## 驗收\n```bash\ntrue\n```\n' "$c" > "$orig"
  cp "$orig" "$T/$c.want"
  rm -f "$SEEN"/*
  id="$("$R/bin/dcq" add "$orig" "$T/w" easy 2>/dev/null)" || { echo "not ok - $c add 失敗"; fail=1; continue; }
  snap="$(sed -n 's/^TASK=//p' "$DCQ_HOME/pending/$id.job")"
  chk "$c TASK 指向 .src 快照" "$snap" "$DCQ_HOME/.src/$id/$c.md"
  chk "$c ORIG_TASK 記原路徑" "$(sed -n 's/^ORIG_TASK=//p' "$DCQ_HOME/pending/$id.job")" "$orig"
  case "$c" in
    overwrite) printf 'garbage { \n' > "$orig" ;;
    truncate)  : > "$orig" ;;
    delete)    rm -f "$orig" ;;
  esac
  DCQ_ALLOWED_FAILS=0 "$R/bin/dcq" run -j 1 >/dev/null 2>&1
  chk "$c 來源改動後仍讀入列當下內容" "$(cmp -s "$SEEN/$c.seen" "$T/$c.want" && echo same)" "same"
done

# pending 取消結案必須同步收快照。
printf '# cancel\n' > "$T/cancel.md"
id="$("$R/bin/dcq" add "$T/cancel.md" "$T/w" easy 2>/dev/null)"
"$R/bin/dcq" cancel "$id" >/dev/null 2>&1
chk "pending 取消落 failed 並清快照" "$([ -e "$DCQ_HOME/failed/$id.job" ] && [ ! -e "$DCQ_HOME/.src/$id" ] && echo yes)" "yes"

# job 檔 mv 失敗：假 mv 只讓 *.job.tmp 那一步失敗 → 非 0、pending 沒新 job、不留 tmp
cat > "$T/bin/mv" <<'EOF'
#!/bin/sh
case "$*" in *.job.tmp*) exit 1 ;; esac
exec /bin/mv "$@"
EOF
chmod +x "$T/bin/mv"
printf '# mvfail\n' > "$T/m.md"
before="$(ls "$DCQ_HOME/pending" 2>/dev/null | wc -l | tr -d ' ')"
"$R/bin/dcq" add "$T/m.md" "$T/w" easy >/dev/null 2>&1; rc=$?
chk "mv 失敗 add 非 0" "$([ "$rc" -ne 0 ] && echo yes)" "yes"
chk "mv 失敗 pending 沒新 job" "$(ls "$DCQ_HOME/pending" 2>/dev/null | wc -l | tr -d ' ')" "$before"
chk "mv 失敗不留 tmp" "$(ls -A "$DCQ_HOME/pending" 2>/dev/null | grep -c '\.tmp$')" "0"

# 快照函式失敗（寫不進去）→ 非 0、pending 沒新 job、不留快照 tmp
rm -f "$T/bin/mv"
chmod 500 "$DCQ_HOME/.src"
before="$(ls "$DCQ_HOME/pending" 2>/dev/null | wc -l | tr -d ' ')"
"$R/bin/dcq" add "$T/m.md" "$T/w" easy >/dev/null 2>&1; rc=$?
chmod 700 "$DCQ_HOME/.src"
chk "快照寫入失敗 add 非 0" "$([ "$rc" -ne 0 ] && echo yes)" "yes"
chk "快照寫入失敗 pending 沒新 job" "$(ls "$DCQ_HOME/pending" 2>/dev/null | wc -l | tr -d ' ')" "$before"
chk "快照寫入失敗不留 tmp" "$(find "$DCQ_HOME/.src" -name '*.tmp' | wc -l | tr -d ' ')" "0"

# WO-F2 §1：舊單（快照上線前入列）原檔已不存在、補快照失敗 → 這張單落 failed，假 dc 一次都不該被叫
printf '#!/usr/bin/env bash\necho called >> "$SEEN/legacy.called"\nexit 0\n' > "$T/bin/dc"; chmod +x "$T/bin/dc"
id="$("$R/bin/dcq" add "$T/m.md" "$T/w" easy 2>/dev/null)" || { echo "not ok - 舊單 add 失敗"; fail=1; }
j="$DCQ_HOME/pending/$id.job"
sed -i.bak "s#^TASK=.*#TASK=$T/gone.md#" "$j" && rm -f "$j.bak"
rm -rf "$DCQ_HOME/.src/$id"
DCQ_ALLOWED_FAILS=9 "$R/bin/dcq" run -j 1 >"$T/run-legacy.out" 2>&1
chk "舊單補快照失敗落 failed" "$([ -e "$DCQ_HOME/failed/$id.job" ] && echo yes)" "yes"
chk "舊單補快照失敗沒叫 dc" "$([ -e "$SEEN/legacy.called" ] && echo yes)" ""
chk "舊單補快照失敗 log 寫原因" "$(grep -c '舊單補快照失敗' "$T/run-legacy.out")" "1"
# 舊單補快照失敗發生在 claim_one（wt_setup 之前）也算：乾淨 git repo 才走得到那條
git init -q "$T/w" && git -C "$T/w" -c user.email=t@t -c user.name=t commit -q --allow-empty -m w
write_dc
id="$("$R/bin/dcq" add "$T/m.md" "$T/w" easy 2>/dev/null)" || { echo "not ok - 舊單 add 失敗"; fail=1; }
j="$DCQ_HOME/pending/$id.job"
sed -i.bak "s#^TASK=.*#TASK=$T/gone2.md#" "$j" && rm -f "$j.bak"
rm -rf "$DCQ_HOME/.src/$id"
rm -f "$SEEN/legacy.called"
DCQ_ALLOWED_FAILS=9 "$R/bin/dcq" run -j 1 >"$T/run-legacy2.out" 2>&1
chk "舊單（claim 前）補快照失敗落 failed" "$([ -e "$DCQ_HOME/failed/$id.job" ] && echo yes)" "yes"
chk "舊單（claim 前）補快照失敗沒叫 dc" "$([ -e "$SEEN/legacy.called" ] && echo yes)" ""

# WO-F2 §3：done／failed 結案後 .src/<id> 收掉
write_dc
printf '# sd\n' > "$T/sd.md"; printf '# sf\n' > "$T/sf.md"
idd="$("$R/bin/dcq" add "$T/sd.md" "$T/w" easy 2>/dev/null)"
idf="$("$R/bin/dcq" add "$T/sf.md" "$T/w" easy 2>/dev/null)"
chk "結案前 .src 有快照" "$([ -d "$DCQ_HOME/.src/$idd" ] && [ -d "$DCQ_HOME/.src/$idf" ] && echo yes)" "yes"
# 假 dc：sf 這張失敗，其餘成功（名字從工單內容 `# <name>` 取）
printf '#!/usr/bin/env bash\ncase "$(sed -n '\''s/^# //p'\'' "$1" | head -1)" in sf) exit 1 ;; esac\nexit 0\n' > "$T/bin/dc"; chmod +x "$T/bin/dc"
DCQ_ALLOWED_FAILS=9 "$R/bin/dcq" run -j 1 >/dev/null 2>&1
chk "done 結案刪 .src" "$([ -e "$DCQ_HOME/done/$idd.job" ] && [ ! -e "$DCQ_HOME/.src/$idd" ] && echo yes)" "yes"
chk "failed 結案刪 .src" "$([ -e "$DCQ_HOME/failed/$idf.job" ] && [ ! -e "$DCQ_HOME/.src/$idf" ] && echo yes)" "yes"

# 孤兒快照（沒有 job 指到）由 run 的 wt_gc 收掉；clear 後 .src 全清
"$R/bin/dcq" add "$T/m.md" "$T/w" easy >/dev/null 2>&1
mkdir -p "$DCQ_HOME/.src/999999-orphan"; printf x > "$DCQ_HOME/.src/999999-orphan/o.md"
touch -t 200001010000 "$DCQ_HOME/.src/999999-orphan"
mkdir -p "$DCQ_HOME/.src/recent" "$DCQ_HOME/.src/writing"
touch -t 200001010000 "$DCQ_HOME/.src/writing"
: > "$DCQ_HOME/pending/.writing.job.tmp"
# 直接呼叫正式 gc：runner 的空佇列判斷包含隱藏 jtmp，不能等它自然退出。
(
  Q="$DCQ_HOME"
  now() { date +%s; }
  eval "$(sed -n '/^mtime() /p; /^wt_gc()/,/^}/p' "$R/bin/dcq")"
  wt_gc
)
chk "新快照 gc 保護 10 分鐘" "$([ -d "$DCQ_HOME/.src/recent" ] && echo yes)" "yes"
chk "有 jtmp 的舊快照 gc 保留" "$([ -d "$DCQ_HOME/.src/writing" ] && echo yes)" "yes"
rm -f "$DCQ_HOME/pending/.writing.job.tmp"
chk "孤兒快照被 gc 收掉" "$([ -e "$DCQ_HOME/.src/999999-orphan" ] && echo yes)" ""
"$R/bin/dcq" add "$T/m.md" "$T/w" easy >/dev/null 2>&1
"$R/bin/dcq" clear >/dev/null 2>&1
chk "clear 後 .src 不留" "$(ls "$DCQ_HOME/.src" 2>/dev/null | wc -l | tr -d ' ')" "0"

# WO-F2 §3：job 檔發布失敗（假 mv 只讓 *.job.tmp 失敗）→ 剛建的快照不殘留
cat > "$T/bin/mv" <<'EOF'
#!/bin/sh
case "$*" in *.job.tmp*) exit 1 ;; esac
exec /bin/mv "$@"
EOF
chmod +x "$T/bin/mv"
n0="$(ls "$DCQ_HOME/.src" 2>/dev/null | wc -l | tr -d ' ')"
"$R/bin/dcq" add "$T/m.md" "$T/w" easy >/dev/null 2>&1
chk "發布失敗不留快照" "$([ "$(ls "$DCQ_HOME/.src" 2>/dev/null | wc -l | tr -d ' ')" = "$n0" ] && [ -z "$(find "$DCQ_HOME/.src" -name '.snap-failed' 2>/dev/null)" ] && echo yes)" "yes"
rm -f "$T/bin/mv"

# 初次 job 寫入失敗：快照 mv 成功後封住 pending。
cat > "$T/bin/mv" <<'EOF'
#!/bin/sh
/bin/mv "$@" || exit $?
case "$2" in
  "$DCQ_HOME"/.src/*/*)
    /bin/mv "$DCQ_HOME/pending" "$DCQ_HOME/pending.saved"
    : > "$DCQ_HOME/pending"
    ;;
esac
EOF
chmod +x "$T/bin/mv"
cat > "$T/bin/mkdir" <<'EOF'
#!/bin/sh
[ "$*" = "-p $DCQ_HOME/pending" ] && exit 0
exec /bin/mkdir "$@"
EOF
chmod +x "$T/bin/mkdir"
n0="$(ls "$DCQ_HOME/.src" | wc -l | tr -d ' ')"
"$R/bin/dcq" add "$T/m.md" "$T/w" easy >"$T/write.out" 2>&1; rc=$?
chk "初寫失敗 add 非 0" "$([ "$rc" -ne 0 ] && echo yes)" "yes"
chk "初寫失敗確實到寫入閘" "$(grep -c '寫 job 檔失敗' "$T/write.out")" "1"
chk "初寫失敗清掉快照" "$(ls "$DCQ_HOME/.src" | wc -l | tr -d ' ')" "$n0"
rm -f "$T/bin/mv" "$T/bin/mkdir" "$DCQ_HOME/pending"
/bin/mv "$DCQ_HOME/pending.saved" "$DCQ_HOME/pending"

[ "$fail" = 0 ] && echo PASS
exit "$fail"
