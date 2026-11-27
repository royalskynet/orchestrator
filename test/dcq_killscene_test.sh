#!/usr/bin/env bash
# issue #32：dc 不理 SIGTERM、killtree 升級 KILL 前留現場檔（行程樹＋輸出尾 20 行）。
# 驗收：trap '' TERM 假 dc、DCQ_KILL_GRACE=2，收工後 $Q/logs/killscene.* 存在、
# 記到假 dc 的 pid 與 STAT、含 .out 尾的標記行。正常理會 TERM 的不留檔。
# 變異：拿掉 killscene 呼叫，前者斷言全失敗。
set -u
. "$(dirname "$0")/env.sh"
R="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
export PATH="$T/bin:$PATH"
export DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1 DCQ_STALL_S=2 DCQ_TOK_POLL_S=1 DCQ_LOOP=0 DCQ_SPIN_S=0
export DCQ_ATTEMPT_MAX=99 DCQ_TOK_MAX=0 DCQ_COST_MAX=0 DCQ_JOB_TOK_MAX=0
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"
export DCQ_FREE_ROUNDS=1 DCQ_POOL_PAID="" DCQ_POOL_TAIL=""
export DCQ_AUTORANK=0 DCQ_POOLSYNC=0 DCQ_GO_STATE="$T/none.json"
mkdir -p "$T/bin" "$T/wd"
fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }

write_common_bins() {
  # 假 opencode：不干擾 stall_dump
  cat > "$T/bin/opencode" <<'SH'
#!/bin/sh
case "$1" in
  session) printf '[{"id":"ses_fake","directory":"%s","created":%s}]\n' "$(pwd -P)" "$(date +%s)000" ;;
  export)  printf '%s\n' '{"messages":[{"info":{"role":"assistant","tokens":{"output":5},"time":{"completed":1}},"parts":[{"type":"text","text":"x"}]}]}' ;;
esac
SH
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/deep-lint"
  printf '#!/bin/sh\ncase "$*" in *--dry*) exit 0 ;; esac\nexit 1\n' > "$T/bin/wo-verify"
  chmod +x "$T/bin/opencode" "$T/bin/deep-lint" "$T/bin/wo-verify"
}

setup_case() { # $1=dcq_dir $2=qdir $3=dc_script：建假 dc、入列、跑 dcq run（TERM 無感的要 KILL 才收工）
  local dcq_dir="$1" qdir="$2" dc_script="$3"
  export DCQ_HOME="$T/$qdir" DC_BIN="$T/bin"
  mkdir -p "$DCQ_HOME"
  write_common_bins
  printf '%s\n' "$dc_script" > "$T/bin/dc"; chmod +x "$T/bin/dc"
  printf '# s\n' > "$T/$qdir.md"
  "$dcq_dir/dcq" add "$T/$qdir.md" "$T/wd" >/dev/null 2>&1
  (
    export DCQ_MODELS="m1" DCQ_KILL_GRACE=2 DCQ_STALL_S=2 DCQ_SPIN_S=0 DCQ_LOOP=0
    export DCQ_ATTEMPT_MAX=99 DCQ_ALLOWED_FAILS=99 DCQ_JOB_MAX=99 DCQ_POLL_S=1
    "$dcq_dir/dcq" run -j 1 >"$T/$qdir.out" 2>&1
  )
}

# Case 1: dc ignores TERM -> KILL 前有現場檔，內容含 pid、行程狀態、輸出尾標記
setup_case "$R/bin" q1 '#!/bin/sh
trap '\'''\'' TERM
echo MARKER_KILLSCENE_LINE
echo $$ > "$DCQ_HOME/fake_dc.pid"
sleep 60
'
fake_pid="$(cat "$T/q1/fake_dc.pid" 2>/dev/null || true)"
scene="$(ls "$T/q1/logs/"killscene.* 2>/dev/null | head -1)"
chk "升級KILL前留現場檔" "$([ -n "$scene" ] && [ -s "$scene" ] && echo yes || echo no)" "yes"
if [ -n "$scene" ]; then
  chk "現場檔記到假dc pid" "$(grep -c "pid=$fake_pid" "$scene" 2>/dev/null)" "1"
  chk "現場檔含行程樹狀態" "$(grep -c 'STAT' "$scene" 2>/dev/null)" "1"
  chk "現場檔含輸出尾標記" "$(grep -c 'MARKER_KILLSCENE_LINE' "$scene" 2>/dev/null)" "1"
fi
if [ -n "$fake_pid" ] && kill -0 "$fake_pid" 2>/dev/null; then
  echo "FAIL 假dc已被KILL: pid $fake_pid still alive"; fail=1
  kill -KILL "$fake_pid" 2>/dev/null || true
else
  echo "PASS 假dc已被KILL"
fi

# Case 2: dc handles TERM normally -> 沒升級 KILL 就不留現場檔
setup_case "$R/bin" q2 '#!/bin/sh
echo $$ > "$DCQ_HOME/fake_dc.pid"
sleep 60
'
chk "正常TERM不留現場檔" "$(ls "$T/q2/logs/"killscene.* 2>/dev/null | wc -l | tr -d ' ')" "0"

# Case 3: mutation - 拿掉 killscene 呼叫，Case 1 的斷言要咬不到（證明測試有盯住這條）
MUT="$T/mut/bin"; mkdir -p "$MUT"
for f in "$R/bin/"*; do [ "$(basename "$f")" = dcq ] || ln -s "$f" "$MUT/"; done
cp "$R/bin/dcq" "$MUT/dcq"
perl -i -0pe 's/^    killscene "\$p" "\$out"$/    : # killscene removed/m' "$MUT/dcq"
if grep -q 'killscene removed' "$MUT/dcq"; then
  setup_case "$MUT" q3 '#!/bin/sh
trap '\'''\'' TERM
echo $$ > "$DCQ_HOME/fake_dc.pid"
sleep 60
'
  chk "變異版不留現場檔" "$(ls "$T/q3/logs/"killscene.* 2>/dev/null | wc -l | tr -d ' ')" "0"
else
  echo "FAIL 變異沒改到 killscene 行"; fail=1
fi
fake_pid="$(cat "$T/q3/fake_dc.pid" 2>/dev/null || true)"
[ -n "$fake_pid" ] && kill -KILL "$fake_pid" 2>/dev/null || true

[ "$fail" = 0 ] && echo "PASS dcq_killscene_test" || echo "FAIL dcq_killscene_test"
exit "$fail"
