#!/usr/bin/env bash
# issue #26：oc_usage 從 opencode.db 加總這次嘗試的 token／cost，watch_oc 寫進 gaps.tsv 第 8–10 欄。
# 假 db 建在暫存目錄（DCQ_OC_DB 指向它），不碰真的 ~/.local/share/opencode/opencode.db。
set -u
. "$(dirname "$0")/env.sh"
R="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DCQ_HOME="$T/q" DC_BIN="$T/bin" PATH="$T/bin:$PATH" DCQ_OC_DB="$T/oc.db"
export DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"   # 不讀真的全域閘檔
export DCQ_FREE_ROUNDS=1 DCQ_POOL_PAID="" DCQ_POOL_TAIL=""
export DCQ_AUTORANK=0 DCQ_POOLSYNC=0 DCQ_GO_STATE="$T/none.json"
mkdir -p "$T/bin" "$T/wc" "$T/wo" "$T/wj"
fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }

# 假 opencode.db：欄位摘真實 1.19.4 schema 的最小集（session.id/directory/time_created、
# message.id/session_id/time_created/time_updated/data；data 是 JSON）。
sqlite3 "$DCQ_OC_DB" <<'SQL'
CREATE TABLE session (id text PRIMARY KEY, directory text NOT NULL, time_created integer NOT NULL);
CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
SQL
ms=$(( $(date +%s) * 1000 ))
# ses_old（同目錄、較舊）要被「取最新」剔除；ses_main＝最新：assistant×2＋user×1（user 不算）；
# ses_other 在別的目錄，整個不算。
sqlite3 "$DCQ_OC_DB" <<SQL
INSERT INTO session VALUES ('ses_old','$T/wc',$(( ms - 10 )));
INSERT INTO session VALUES ('ses_main','$T/wc',$ms);
INSERT INTO session VALUES ('ses_other','$T/wo',$ms);
INSERT INTO message VALUES ('m1','ses_old',$ms,$ms,'{"role":"assistant","cost":7,"tokens":{"input":700,"output":70,"reasoning":7,"cache":{"read":70,"write":7}}}');
INSERT INTO message VALUES ('m2','ses_main',$ms,$ms,'{"role":"assistant","cost":0.5,"tokens":{"input":100,"output":10,"reasoning":5,"cache":{"read":20,"write":2}},"modelID":"m","providerID":"p"}');
INSERT INTO message VALUES ('m3','ses_main',$ms,$ms,'{"role":"user","cost":9,"tokens":{"input":900,"output":90,"reasoning":9,"cache":{"read":90,"write":9}}}');
INSERT INTO message VALUES ('m4','ses_main',$ms,$ms,'{"role":"assistant","cost":0.25,"tokens":{"input":50,"output":30,"reasoning":0,"cache":{"read":0,"write":0}},"modelID":"m","providerID":"p"}');
INSERT INTO message VALUES ('m5','ses_other',$ms,$ms,'{"role":"assistant","cost":3,"tokens":{"input":300,"output":33,"reasoning":3,"cache":{"read":30,"write":3}}}');
SQL

# 1) oc_usage 直接測：out＝output＋reasoning（10+5+30=45）、in＝input＋cache.read＋cache.write（122+50=172）、cost＝0.75
eval "$(sed -n '/^oc_usage()/,/^}/p' "$R/bin/dcq")"
chk "oc_usage 加總對（最新 session、只算 assistant）" "$(oc_usage "$T/wc" $(( $(date +%s) - 60 )))" "45 172 0.75"
# 2) db 不存在：回空字串、rc 0
o="$(DCQ_OC_DB="$T/no.db" oc_usage "$T/wc" 1)"; chk "db 不存在回空字串" "$o" ""
DCQ_OC_DB="$T/no.db" oc_usage "$T/wc" 1 >/dev/null; chk "db 不存在 rc 0" "$?" "0"
# 3) 找不到 session（ta 在未來）：回空字串
# 工單目錄經符號連結（macOS /tmp → /private/tmp 同理）：opencode 存實體路徑，用連結路徑也要查得到
mkdir -p "$T/real"; ln -s "$T/real" "$T/link"
sqlite3 "$DCQ_OC_DB" "INSERT INTO session VALUES ('ses_link','$(cd "$T/real" && pwd -P)',$(( $(date +%s) * 1000 ))); INSERT INTO message VALUES ('msg_link','ses_link',1,1,'{\"role\":\"assistant\",\"cost\":0.1,\"tokens\":{\"input\":3,\"output\":7,\"reasoning\":0,\"cache\":{\"read\":0,\"write\":0}}}');"
chk "符號連結目錄查得到 session" "$(oc_usage "$T/link" $(( $(date +%s) - 60 )))" "7 3 0.1"
chk "找不到 session 回空字串" "$(oc_usage "$T/wc" $(( $(date +%s) + 60 )))" ""

# 4) 跑一張假工單：假 dc 在嘗試期間把 session＋訊息寫進假 db（time_created ≥ ta），
#    gaps.tsv 最後一行要有 10 欄、第 8–10 欄是加總值
cat > "$T/bin/dc" <<'EOF'
#!/usr/bin/env bash
cwd="$2"; ms=$(( $(date +%s) * 1000 ))
sqlite3 "$DCQ_OC_DB" <<SQL
INSERT INTO session VALUES ('ses_run','$cwd',$ms);
INSERT INTO message VALUES ('r1','ses_run',$ms,$ms,'{"role":"assistant","cost":0.5,"tokens":{"input":40,"output":8,"reasoning":2,"cache":{"read":10,"write":0}}}');
INSERT INTO message VALUES ('r2','ses_run',$ms,$ms,'{"role":"assistant","cost":0,"tokens":{"input":5,"output":6,"reasoning":0,"cache":{"read":0,"write":1}}}');
SQL
sleep 1
exit 0
EOF
chmod +x "$T/bin/dc"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/deep-lint"; chmod +x "$T/bin/deep-lint"
printf '#!/bin/sh\ncase "$*" in *--dry*) exit 0 ;; esac\nexit 0\n' > "$T/bin/wo-verify"; chmod +x "$T/bin/wo-verify"
printf '# u1\n' > "$T/u1.md"
dcq() { "$R/bin/dcq" "$@"; }
dcq add "$T/u1.md" "$T/wj" >/dev/null
DCQ_MODELS="m1" dcq run -j 1 >"$T/run.out" 2>&1
chk "工單跑完" "$(ls -1 "$DCQ_HOME/done" | wc -l | tr -d ' ')" "1"
last="$(tail -1 "$DCQ_HOME/logs/gaps.tsv")"
chk "gaps.tsv 最後一行 10 欄" "$(printf '%s\n' "$last" | awk -F'\t' '{print NF}')" "10"
chk "第 8 欄 out_tok（8+2+6=16）" "$(printf '%s\n' "$last" | awk -F'\t' '{print $8}')" "16"
chk "第 9 欄 in_tok（40+10+5+1=56）" "$(printf '%s\n' "$last" | awk -F'\t' '{print $9}')" "56"
chk "第 10 欄 cost" "$(printf '%s\n' "$last" | awk -F'\t' '{print $10}')" "0.5"

[ "$fail" = 0 ] && echo PASS
exit "$fail"
