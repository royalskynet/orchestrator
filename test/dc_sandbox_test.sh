#!/usr/bin/env bash
# dc 執行人禁讀自檢（fixindex 11507，2026-10-28）：用假 opencode，不打上游。
# 為什麼要有：eval 的 opencode 執行人用絕對路徑 tail 了真 session transcript 送上游；換 HOME 擋不住。
#   1) 預設：執行人讀 $HOME/.creds、$HOME/.claude/projects 都失敗，讀工單 cwd 正常
#   2) DC_SANDBOX=0：讀得到（證明測試抓得到外洩）
set -u
. "$(dirname "$0")/env.sh"
OC="$(cd "$(dirname "$0")/.." && pwd)/bin/dc"
command -v sandbox-exec >/dev/null || { echo "SKIP 無 sandbox-exec"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"
mkdir -p "$T/bin" "$T/home/.creds/kv" "$T/home/.claude/projects/p" "$T/r"
echo SECRET > "$T/home/.creds/kv/K.txt"
echo CFGKEY > "$T/home/.creds/kv/CFG.txt"
mkdir -p "$T/home/.config/opencode"
printf '{"provider":{"x":{"options":{"apiKey":"{file:~/.creds/kv/CFG.txt}"}},"y":{"options":{"apiKey":"{file:~/.creds/kv/../K.txt}"}}}}' > "$T/home/.config/opencode/opencode.json"
echo TRANSCRIPT > "$T/home/.claude/projects/p/s.jsonl"
echo OK > "$T/r/in.txt"
export HOME="$T/home" DC_BIN="$T/bin" PATH="$T/bin:$PATH" DCQ_HOME="$T/q"
export DC_FREECHECK=off DC_NO_TIMEOUT_WARN=1 DC_NEGCTL=0
unset DC_LOCK_HELD
cat > "$T/bin/opencode" <<'EOS'
#!/usr/bin/env bash
{ cat "$HOME/.creds/kv/CFG.txt"; cat "$HOME/.creds/kv/K.txt"; cat "$HOME/.claude/projects/p/s.jsonl"; ls "$HOME/.creds/kv"; cat in.txt; } > "$FAKE_OUT" 2>/dev/null
exit 0
EOS
chmod +x "$T/bin/opencode"
for g in deep-lint wo-verify; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$g"; chmod +x "$T/bin/$g"; done
printf '# t\n' > "$T/t.md"
fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
has() { grep -qx "$1" "$T/out" && echo y || echo n; }

FAKE_OUT="$T/out" "$OC" "$T/t.md" "$T/r" >"$T/o" 2>&1
chk "預設：dc rc=0" "$?" "0"
chk "預設：讀不到 .creds" "$(has SECRET)" "n"
chk "預設：讀不到 .claude/projects" "$(has TRANSCRIPT)" "n"
chk "預設：目錄本身也列不出（11354）" "$(has K.txt)" "n"
chk "預設：工單 cwd 照讀" "$(has OK)" "y"
chk "預設：opencode.json 引用的 kv 檔放行" "$(has CFGKEY)" "y"

FAKE_OUT="$T/out" DC_SANDBOX=0 "$OC" "$T/t.md" "$T/r" >"$T/o" 2>&1
chk "DC_SANDBOX=0：讀得到 .creds（測試會抓外洩）" "$(has SECRET)" "y"
chk "DC_SANDBOX=0：列得出目錄" "$(has K.txt)" "y"
exit "$fail"
