#!/usr/bin/env bash
# issue #22：測試／其他佇列的 runner 不佔正式 socket（-L dcq），doctor 抓得到跑錯地方的 runner。
# 假 tmux（PATH 注入），不碰真 tmux；假 dc，不打上游。
set -u
. "$(dirname "$0")/env.sh"
R="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
export DCQ_HOME="$T/q" DC_BIN="$T/bin" PATH="$T/bin:$PATH"
export DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1 DCQ_AUTORANK=0 DCQ_POOLSYNC=0 DCQ_GO_STATE="$T/none.json"
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json" DCQ_POOL_TAIL="" DCQ_POOL_PAID=""
export XDG_CONFIG_HOME="$T/xdg" XDG_DATA_HOME="$T/nodata"
unset DCQ_POOL_ZEN DCQ_MODELS DCQ_EASY_ONLY
mkdir -p "$T/bin" "$T/w" "$T/xdg/opencode"
echo '{}' > "$T/xdg/opencode/opencode.json"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/dc"
for g in deep-lint wo-verify; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$g"; done
chmod +x "$T/bin/"*

# 假 tmux：pane 命令放檔案 $T/pane（空檔＝沒有 session），不吞環境、不起真 session，碰不到真 -L dcq。
cat > "$T/bin/tmux" <<SH
#!/bin/sh
case "\$*" in
  *has-session*) [ -s "$T/pane" ] || exit 1 ;;
  *list-panes*) [ -s "$T/pane" ] || exit 1; cat "$T/pane" ;;
  *new-session*) printf '%s\n' "\$*" >> "$T/trace" ;;
  "-L dcq kill-session -t run") echo killed >> "$T/trace"; : > "$T/pane" ;;
esac
exit 0
SH
chmod +x "$T/bin/tmux"
: > "$T/trace"; : > "$T/pane"

# 固定拿來源自己的 dcq_sock（legit 的；不從這裡補修正，不然被突變時這份會把突變救回來）
sed -n '/^dcq_sock() {/,/^}/p' "$R/bin/dcq" > "$T/fix"
D="$R/bin/dcq"   # 斷言跑來源本身

fail=0
chk() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: got '$2' want '$3'"; fail=1; fi; }
sock_of() {  # $1=dcq 檔；回傳假 tmux 收到的 -L 參數
  : > "$T/trace"; JOBS=2 "$1" start >/dev/null 2>&1
  sed -n 's/^-L \([^ ]*\) new-session.*/\1/p' "$T/trace" | head -1
}

# env.sh 的 DCQ_TMUX（dcqtest$$）本身就不是正式 socket；先跑這條再 unset（同一行程，反序不重置會蓋掉）
chk "env.sh 的 DCQ_TMUX 不是正式 socket" "$([ "${DCQ_TMUX:-}" != dcq ] && [ -n "${DCQ_TMUX:-}" ] && echo yes)" "yes"
chk "暫存佇列帶 env.sh 的 DCQ_TMUX 時 socket 照它" "$(sock_of "$D")" "$DCQ_TMUX"
unset DCQ_TMUX
# (1) 非正式佇列、沒設 DCQ_TMUX：socket 不是 dcq（也不是空）
chk "暫存佇列沒設 DCQ_TMUX 不碰 -L dcq" "$(sock_of "$D")" "dcq-$(printf %s "$DCQ_HOME" | cksum | cut -d' ' -f1)"
# (2) 正式佇列：socket 是 dcq（假 tmux，不會真起 runner）
chk "正式佇列沒設 DCQ_TMUX 用 -L dcq" "$(DCQ_HOME="$HOME/.dcq" sock_of "$D")" "dcq"
# (2b) 有 DCQ_TMUX 就照它
chk "DCQ_TMUX 優先" "$(DCQ_TMUX="my-sock$$" sock_of "$D")" "my-sock$$"

# (3) doctor：-L dcq 上的 run 指到暫存佇列要報；指正式佇列不報；--fix 收掉
printf '%s\n' "DCQ_HOME=$T/q $R/bin/dcq run -j 2 >> $T/q/logs/runner.log 2>&1" > "$T/pane"
"$R/bin/dcq" doctor >"$T/d1" 2>&1
chk "doctor 抓得到指向 $T/q 的 runner" "$(grep -cF "FAIL tmux -L dcq 上有 runner 指向非正式佇列" "$T/d1")" "1"
printf '%s\n' "DCQ_HOME=$HOME/.dcq $R/bin/dcq run -j 2" > "$T/pane"
"$R/bin/dcq" doctor >"$T/d2" 2>&1
chk "doctor 不報正式佇列的 runner" "$(grep -c '^FAIL' "$T/d2")" "0"
printf '%s\n' "DCQ_HOME=$T/q $R/bin/dcq run -j 2" > "$T/pane"
: > "$T/trace"
"$R/bin/dcq" doctor --fix >"$T/d3" 2>&1
chk "doctor --fix 收掉跑錯地方的 runner" "$(grep -c '^killed$' "$T/trace")" "1"

[ "$fail" = 0 ] || for f in "$T"/d?; do echo "--- $f ---"; cat "$f"; done
[ "$fail" = 0 ] && echo PASS
exit "$fail"
