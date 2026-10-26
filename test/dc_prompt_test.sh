#!/usr/bin/env bash
# dc 的執行人瘦身：派工時執行人必須拿不到主 session 的 ~/.claude（CLAUDE.md ＋ skills），
# 且 skill 工具要禁用，另掛一份 dc 專用的執行人規則。實測輸入 21.6k → 7.2k token。
# 用假的 opencode 記下它實際收到的環境變數，不打上游、不發 TG。
set -u
. "$(dirname "$0")/env.sh"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DC="$REPO/bin/dc"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DEBUG_MARK="$T/debug.mark"
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"   # 不讀真的全域閘（10-19：Jev 閘封鎖時這些測試全掛）
mkdir -p "$T/bin" "$T/w" "$T/cfg"
export DC_BIN="$T/bin" PATH="$T/bin:$PATH"
export DCQ_HOME="$T/q" XDG_CONFIG_HOME="$T/cfg"
# DC_NEGCTL=0：這些測試的 wo-verify 是 `exit 0` 的假貨，do-nothing 對照會當場中止派工。
# 負向對照本身由 dc_verify_gate_test.sh 驗。
export DC_FREECHECK=off DC_NO_TIMEOUT_WARN=1 DC_NEGCTL=0
export OPENCODE_API_KEY=fake  # 假 key：測的是傳給 opencode 的設定，不測憑證，也不去讀真的 auth.json
export TRACE="$T/trace"

cat > "$T/bin/opencode" <<'X'
#!/usr/bin/env bash
# Go 分支不准再呼叫 debug config 注入白名單（10-27 改黑名單）；被叫就留痕
if [ "$1" = debug ]; then echo called >> "${DEBUG_MARK:?}"; echo '{"enabled_providers":["opencode"]}'; exit 0; fi
{
  echo "RUN"
  echo "DISABLE=${OPENCODE_DISABLE_CLAUDE_CODE-<unset>}"
  echo "CONFIG=${OPENCODE_CONFIG_CONTENT-<unset>}"
  echo "BASHTO=${OPENCODE_EXPERIMENTAL_BASH_DEFAULT_TIMEOUT_MS-<unset>}"
} >> "$TRACE"
X
for g in deep-lint wo-verify hpush; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$g"; done
chmod +x "$T/bin"/*
printf '# t\n' > "$T/t.md"

fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
run() { : > "$TRACE"; env "$@" "$DC" "$T/t.md" "$T/w" >/dev/null 2>&1; }
field() { sed -n "s/^$1=//p" "$TRACE" | head -1; }
# 三項核心斷言：關讀、禁 skill 工具、掛 dc 自己的規則檔（經 symlink 呼叫也要指到 repo 裡那份）
core() {
  chk "$1 關讀主 session 的 ~/.claude"  "$(field DISABLE)" "1"
  chk "$1 skill 工具禁用"             "$(field CONFIG | jq -r '.permission.skill // "-"')" "deny"
  i="$(field CONFIG | jq -r '.instructions[0] // "-"')"
  case "$i" in */executor-rules.md) ;; *) i="bad:$i" ;; esac
  chk "$1 掛上 repo 的 executor-rules.md" "$([ -f "$i" ] && echo "$i" || echo "not-a-file:$i")" "$REPO/executor-rules.md"
}

run DC_FREE_MODEL=opencode/longcat-2.5-preview-free
chk "免費 Zen 派工有走到 opencode run" "$([ -s "$TRACE" ] && echo ran || echo skipped)" "ran"
core "Zen"
# bash 工具預設 120s 會砍掉模型自跑的慢測試（10-21）；呼叫端自己設的值不能被蓋掉
chk "bash 工具逾時注入 300s" "$(field BASHTO)" "300000"
run DC_FREE_MODEL=opencode/longcat-2.5-preview-free OPENCODE_EXPERIMENTAL_BASH_DEFAULT_TIMEOUT_MS=1234
chk "呼叫端設的 bash 逾時保留" "$(field BASHTO)" "1234"

# Go 分支：不再注入 enabled_providers 白名單（v2 會讓 Go 消失，fix 11477），也不呼叫 debug config
rm -f "$DEBUG_MARK"
run DC_FREE_MODEL=opencode-go/space-bunny-free
core "Go"
chk "Go 不注入 enabled_providers" "$(field CONFIG | jq -r 'has("enabled_providers")')" "false"
chk "Go 不呼叫 debug config" "$([ -s "$DEBUG_MARK" ] && echo called || echo none)" "none"

[ "$fail" = 0 ] && echo PASS
exit $fail
