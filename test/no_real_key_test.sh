#!/usr/bin/env bash
# 測試環境不得拿到真的 opencode-go key（使用者 2026-11-26 規則）。
# 不碰真 key：只用靜態 XDG_DATA_HOME 檢查＋受控假 auth.json 證明這支測試咬得到 key 注入。
set -u
. "$(dirname "$0")/env.sh"
DC="$(cd "$(dirname "$0")/.." && pwd)/bin/dc"
TD="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"
mkdir -p "$T/bin" "$T/w" "$T/cfg/opencode"
export DC_BIN="$T/bin" PATH="$T/bin:$PATH" DCQ_HOME="$T/q" XDG_CONFIG_HOME="$T/cfg"
export DC_FREECHECK=off DC_NO_TIMEOUT_WARN=1 DC_NEGCTL=0 TRACE="$T/trace"
cat > "$T/bin/opencode" <<'X'
#!/usr/bin/env bash
if [ -n "${OPENCODE_API_KEY:-}" ]; then echo KEY_PRESENT >> "$TRACE"; else echo KEY_ABSENT >> "$TRACE"; fi
exit 0
X
for g in deep-lint wo-verify; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$g"; done
chmod +x "$T/bin"/*
printf '# t\n' > "$T/t.md"
fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
fixture="$(cd "$TD/fixtures/xdg-empty" && pwd)"
chk "env.sh 把 XDG_DATA_HOME 隔進可寫暫存" "$([ -n "${XDG_DATA_HOME:-}" ] && [ "$XDG_DATA_HOME" != "$HOME/.local/share" ] && [ -d "$XDG_DATA_HOME" ] && echo yes || echo no)" yes
chk "env.sh 預設關 freecheck（避免讀真 Go/Zen key）" "${DC_FREECHECK:-unset}" off
chk "隔離 data home 沒有 opencode auth.json" "$([ -e "${XDG_DATA_HOME:-/nonexistent}/opencode/auth.json" ] && echo present || echo absent)" absent
# 對照：受控假 auth.json 會被 dc 讀出並注入 fake opencode，證明下面的「沒注入」不是永遠成立的白吃斷言。
mkdir -p "$T/xdg/opencode"
printf '%s\n' '{"opencode":{"key":"CONTROLLED_FAKE_KEY"}}' > "$T/xdg/opencode/auth.json"
: > "$TRACE"
( unset OPENCODE_API_KEY; XDG_DATA_HOME="$T/xdg" DC_FREE_MODEL=opencode-go/controlled-free "$DC" "$T/t.md" "$T/w" >/dev/null 2>&1 )
chk "對照：受控假 auth 會注入（測試咬得到）" "$([ "$(grep -c '^KEY_PRESENT$' "$TRACE" 2>/dev/null || echo 0)" -ge 1 ] && echo yes || echo no)" yes
# 本案：測試 fixture 沒 auth，opencode-go 模型要在呼叫 fake opencode 前退出；若有真實 auth 漏進來會看到 KEY_PRESENT。
: > "$TRACE"
( unset OPENCODE_API_KEY; DC_FREE_MODEL=opencode-go/isolated-free "$DC" "$T/t.md" "$T/w" >/dev/null 2>&1 ); rc=$?
chk "隔離：沒 key 時 dc 在派工前退出 rc=2" "$rc" 2
chk "隔離：fake opencode 完全沒被呼叫" "$([ -s "$TRACE" ] && echo called || echo absent)" absent
[ "$fail" = 0 ] && echo PASS
exit "$fail"
