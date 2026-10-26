#!/usr/bin/env bash
# 真 opencode v2 有沒有吃 dc 注入的執行人護欄（fix 11469、本測試 10-27 補）。
# dc_prompt_test 只驗 dc 送出的 OPENCODE_CONFIG_CONTENT；這支驗宿主那一端：
# 拿 dc 實際送出的值起私有 opencode serve，查 /api/agent、/api/config，零 token、不打模型。
# v2 會把舊鍵 permission.skill 轉成 permissions:[{action:skill,effect:deny}]，
# 宿主不吃 env（v2 debug 子指令就是問背景服務、不吃 env）時這支會 fail。非 v2 直接 SKIP。
set -u
_XDG_REAL="${XDG_CONFIG_HOME-}"
. "$(dirname "$0")/env.sh"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OC="${OC_REAL:-$(command -v opencode || echo "$HOME/.opencode/bin/opencode")}"
[ -x "$OC" ] || { echo "SKIP 找不到 opencode"; exit 0; }
case "$("$OC" --version 2>/dev/null)" in *v2.*|2.*) ;; *) echo "SKIP 非 opencode v2（$("$OC" --version 2>/dev/null)）"; exit 0 ;; esac

T="$(mktemp -d)"; trap 'kill $SP 2>/dev/null; rm -rf "$T"' EXIT; SP=
mkdir -p "$T/bin" "$T/w" "$T/cfg"
# 第一步：用假 opencode 接住 dc 實際送出的 OPENCODE_CONFIG_CONTENT（同 dc_prompt_test 的做法）
cat > "$T/bin/opencode" <<'X'
#!/usr/bin/env bash
[ "$1" = debug ] && { echo '{}'; exit 0; }
printf '%s' "${OPENCODE_CONFIG_CONTENT-}" > "${CAP:?}"
X
for g in deep-lint wo-verify hpush; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$g"; done
chmod +x "$T/bin"/*; printf '# t\n' > "$T/t.md"
env PATH="$T/bin:$PATH" DC_BIN="$T/bin" DCQ_HOME="$T/q" XDG_CONFIG_HOME="$T/cfg" CAP="$T/cc.json" \
  DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json" DC_FREECHECK=off DC_NO_TIMEOUT_WARN=1 \
  DC_NEGCTL=0 OPENCODE_API_KEY=fake DC_FREE_MODEL=opencode-go/beam-free \
  "$REPO/bin/dc" "$T/t.md" "$T/w" >/dev/null 2>&1
CC="$(cat "$T/cc.json" 2>/dev/null)"

fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
chk "dc 有送出合法 JSON 的 OPENCODE_CONFIG_CONTENT" "$(printf '%s' "$CC" | jq -e . >/dev/null 2>&1 && echo ok || echo bad)" ok

# 第二步：用真的使用者設定（檔案層會不會蓋掉 env 層正是要驗的）起私有 server
[ -n "$_XDG_REAL" ] && export XDG_CONFIG_HOME="$_XDG_REAL" || unset XDG_CONFIG_HOME
export OPENCODE_DISABLE_CLAUDE_CODE=1 OPENCODE_PASSWORD="$(openssl rand -hex 16)"
PORT=$((47000 + RANDOM % 900))
# 每個 agent 的 permissions 依序比對、後者勝：skill 的最後一條且比任何 *=allow 晚才算擋住
blocked='[.data[] | (.permissions | to_entries) as $p
  | ([$p[] | select(.value.action=="skill" or .value.action=="*") | .value] | last | .effect) as $e
  | {name, e: $e}] | if length>0 and all(.e=="deny") then "deny" else map("\(.name)=\(.e)") | join(",") end'
probe() { # $1=OPENCODE_CONFIG_CONTENT（空＝不設）→ 印出 agent 與 config 兩份 JSON 到 $T/$2.*
  if [ -n "$1" ]; then OPENCODE_CONFIG_CONTENT="$1" "$OC" serve --hostname 127.0.0.1 --port "$PORT" >"$T/$2.log" 2>&1 &
  else env -u OPENCODE_CONFIG_CONTENT "$OC" serve --hostname 127.0.0.1 --port "$PORT" >"$T/$2.log" 2>&1 & fi
  SP=$!
  for _ in $(seq 30); do "$OC" api --server "http://127.0.0.1:$PORT" GET /api/agent >"$T/$2.agent" 2>/dev/null && break; sleep 1; done
  sleep 2  # agent 清單載入是非同步，第一次可能還沒把 config 合進來
  "$OC" api --server "http://127.0.0.1:$PORT" GET /api/agent >"$T/$2.agent" 2>/dev/null
  "$OC" api --server "http://127.0.0.1:$PORT" GET /api/config >"$T/$2.config" 2>/dev/null
  kill $SP 2>/dev/null; wait $SP 2>/dev/null; SP=
}
probe "" ctl
probe "$CC" dc
# 對照組沒擋才證明探針看得到差別（否則可能是 v2 自己就不給 skill）
chk "對照組（不帶 env）skill 沒被擋" "$(jq -r "$blocked" "$T/ctl.agent" 2>/dev/null | grep -c '^deny$')" 0
chk "dc 設定下每個 agent 的 skill 都被擋" "$(jq -r "$blocked" "$T/dc.agent" 2>/dev/null)" deny
chk "dc 設定下 instructions 掛上 executor-rules.md" \
  "$(jq -r '[.. | objects | .instructions? // empty | .[]] | map(select(endswith("/executor-rules.md"))) | length > 0' "$T/dc.config" 2>/dev/null)" true

[ "$fail" = 0 ] && echo PASS
exit $fail
