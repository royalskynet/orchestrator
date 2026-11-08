#!/usr/bin/env bash
# dcq add 沒有 runner 時自動 dcq start（2026-11-07）。
# 假 dc 不打上游；假 tmux 記錄被呼叫的參數。
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
export TMUX_TRACE="$T/tmux_trace"; : > "$TMUX_TRACE"
# 這支就是要測自動啟動：env.sh 預設關掉，這裡開回來（#22）
export DCQ_AUTOSTART=1

cat > "$T/bin/dc" <<'EOF'
#!/usr/bin/env bash
task="$1"; cwd="$2"
exit 0
EOF
chmod +x "$T/bin/dc"
for g in deep-lint wo-verify; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$g"; chmod +x "$T/bin/$g"; done

cat > "$T/bin/tmux" <<'EOF'
#!/usr/bin/env bash
echo "tmux $*" >> "$TMUX_TRACE"
case "$*" in *"has-session"*) exit 1 ;; esac
exit 0
EOF
chmod +x "$T/bin/tmux"

chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
fail=0

mkdir -p "$T/wd"
printf '# a\n' > "$T/a.md"

# (a) 無 runner 時 dcq add 呼叫假 tmux、stdout 只有一行 job id
: > "$TMUX_TRACE"
"$REPO/bin/dcq" add "$T/a.md" "$T/wd" >"$T/out_a" 2>"$T/err_a"
ida="$(cat "$T/out_a")"
chk "stdout 只有一行 job id" "$(wc -l < "$T/out_a" | tr -d ' ')" "1"
chk "呼叫假 tmux (new-session)" "$(grep -c 'new-session' "$TMUX_TRACE")" "1"

# (b) DCQ_AUTOSTART=0 不呼叫 tmux、stderr 含「沒有 runner 在跑」
printf '# b\n' > "$T/b.md"
: > "$TMUX_TRACE"
DCQ_AUTOSTART=0 "$REPO/bin/dcq" add "$T/b.md" "$T/wd" >"$T/out_b" 2>"$T/err_b"
chk "DCQ_AUTOSTART=0 不呼叫 tmux" "$(grep -c 'tmux' "$TMUX_TRACE" 2>/dev/null)" "0"
chk "stderr 含沒有 runner 在跑" "$(grep -c '沒有 runner 在跑' "$T/err_b")" "1"

# (c) 活的 pid 寫入 .runner.pid 時不呼叫 tmux
printf '# c\n' > "$T/c.md"
sleep 300 & live=$!
echo "$live" > "$DCQ_HOME/.runner.pid"
: > "$TMUX_TRACE"
"$REPO/bin/dcq" add "$T/c.md" "$T/wd" >"$T/out_c" 2>"$T/err_c"
chk "活 pid 不呼叫 tmux" "$(grep -c 'tmux' "$TMUX_TRACE" 2>/dev/null)" "0"
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null

# (d) dcq status <pending id> 不含「查無此單」
"$REPO/bin/dcq" status "$ida" >"$T/st.out" 2>"$T/st.err"
if grep -q '查無此單' "$T/st.out" "$T/st.err" 2>/dev/null; then _n=1; else _n=0; fi
chk "status pending 不含查無此單" "$_n" "0"

[ "$fail" = 0 ] || { echo "--- out_a ---"; cat "$T/out_a"; echo "--- err_a ---"; cat "$T/err_a"; echo "--- err_b ---"; cat "$T/err_b"; echo "--- st.out ---"; cat "$T/st.out"; echo "--- st.err ---"; cat "$T/st.err"; }
[ "$fail" = 0 ] && echo PASS
exit $fail