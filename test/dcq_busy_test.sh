#!/usr/bin/env bash
# dcq watchdog：opencode 的工具子程序還在跑時，不判 stall／spin（10-21：模型自跑 164s 的 dcq_test，
# 沒輸出也沒改檔，被 spin／slow 殺掉重跑，WO-1/2 二十個嘗試全滅）。
# 假 dc 底下掛一支叫 opencode 的程序（複製 /bin/sh），它的子程序 sleep＝工具在跑。不打上游。
# #24：idle1 的 spin 會印「空轉」診斷行＋共同殺除行，兩行算一次殺除；每個案例各一個獨立 fixture，
# 分別固定走 stall、spin 分支，並行 3 支重跑不會互相拉低門檻。
set -u
. "$(dirname "$0")/env.sh"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

# 精確的殺除事件計數：只數共同殺除行（含原因與秒數），不把「空轉」診斷行算進去。
busy_watchdog_kill_count() { grep -c 'watchdog: m1 .*，殺掉$' "$1"; }

# 單次案例：$1=stall|spin。各自 mktemp，失敗輸出案例名、trace、run.out。
busy_case() {
  local case="$1" stall_s spin_s fail=0
  case "$case" in
    stall) stall_s=3 spin_s=0 ;;  # spin 關掉：只驗 stall 分支
    spin) stall_s=60 spin_s=3 ;;  # stall 遠大於工具 8s：只驗 spin 分支
  esac
  # 路徑放全域：函式 return 後 local T 消失，EXIT trap（set -u）就讀不到而要清什麼。
  T="$(mktemp -d)"

  export DCQ_HOME="$T/q"; mkdir -p "$T/bin" "$T/xb"
  export DC_BIN="$T/bin" PATH="$T/bin:$PATH"
  export DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1
  export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"
  export DCQ_FREE_ROUNDS=1 DCQ_POOL_PAID="" DCQ_POOL_TAIL="" DCQ_ORDER=default
  export TRACE="$T/trace" XB="$T/xb"; : > "$TRACE"
  cp /bin/sh "$XB/opencode"

  # tool*：opencode 有子程序 8s（工具在跑）；idle*：dc 自己 sleep 8s（沒有工具）。兩者都沒輸出、不改檔。
  # dcq add 會把工單快照成 $Q/.src/<epoch>-<pid>-<name>.task.md 再把快照交給 dc（11-09），
  # 所以案例名稱從工單內容的 `# <name>` 取，不從檔名取（檔名已不是原案例名）。
  cat > "$T/bin/dc" <<'EOF'
#!/usr/bin/env bash
busy_task_name() { sed -n 's/^# //p' "$1" | head -n 1; }
n="$(busy_task_name "$1")"
echo "IN $n $DC_FREE_MODEL" >> "$TRACE"
case "$n" in
  tool1|idle1) ;;
  *) echo "dc: 不明工單名稱 '$n'（$1），只認 tool1／idle1" >&2; exit 2 ;;
esac
case "$n:$DC_FREE_MODEL" in
  tool1:m1) "$XB/opencode" -c 'sleep 8; :' ;;
  idle1:m1) sleep 8 ;;
esac
exit 0
EOF
  chmod +x "$T/bin/dc"
  for g in deep-lint wo-verify; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$g"; chmod +x "$T/bin/$g"; done

  local chk why rc
  chk() { if [ "$2" = "$3" ]; then echo "PASS [$case] $1"; else echo "FAIL [$case] $1: got '$2' want '$3'"; fail=1; fi; }

  for n in tool1 idle1; do
    mkdir -p "$T/$n"; git -C "$T/$n" init -q
    printf '# %s\n' "$n" > "$T/$n.md"
    if "$REPO/bin/dcq" add "$T/$n.md" "$T/$n" >/dev/null; then rc=0; else rc=$?; fi
    chk "dcq add $n rc" "$rc" "0"
  done
  if DCQ_MODELS="m1 m2" DCQ_STALL_S="$stall_s" DCQ_SPIN_S="$spin_s" DCQ_ATTEMPT_MAX=60 DCQ_ALLOWED_FAILS=99 \
    "$REPO/bin/dcq" run -j 2 >"$T/run.out" 2>&1; then rc=0; else rc=$?; fi
  chk "dcq run rc" "$rc" "0"

  busy_failed="${busy_failed:-}$case "  # 先記下正在跑的案例：被訊號打斷時 finish 也知道該印誰
  # 依 job ID 取該 job 的 run.out 行。ID＝<epoch>-<pid>-<案例名>；抽到 ID 後用固定字串比對所有含它的行，不用裸 grep 跨 job 計數。
  job_out() {
    local id
    id="$(sed -n 's/.*dcq\[\([0-9]*-[0-9]*-'"$1"'\)\].*/\1/p' "$T/run.out" | head -n 1)"
    [ -n "$id" ] || return 0
    awk -v k="dcq[$id]" 'index($0, k) == 1' "$T/run.out"
  }
  why="$(job_out idle1 | sed -n 's/.*watchdog: m1 \([a-z]*\)（.*，殺掉$/\1/p')"

  chk "工具在跑不判 stall／spin（tool1 只跑 m1）" "$(grep -c '^IN tool1' "$TRACE")" "1"
  chk "沒工具的靜默照樣殺（idle1 換到 m2）" "$(grep -c '^IN idle1 m2' "$TRACE")" "1"
  chk "watchdog 只殺 idle1" "$(busy_watchdog_kill_count "$T/run.out")" "1"
  chk "tool1 沒有共同殺除訊息" "$(job_out tool1 | grep -c '，殺掉$')" "0"
  chk "idle1 共同殺除訊息只有一次" "$(job_out idle1 | grep -c '，殺掉$')" "1"
  chk "idle1 殺除原因為 $case" "$why" "$case"
  chk "watchdog 訊息印嘗試秒數" "$(grep -c '本次已跑 [0-9]*s，整張 [0-9]*s' "$T/run.out")" "1"
  if [ "$case" = spin ]; then
    chk "spin 案例有空轉診斷行" "$(job_out idle1 | grep -c 'watchdog: m1 空轉（')" "1"
  fi
  chk "tool1 PASS model=m1" "$(job_out tool1 | grep -c 'PASS model=m1$')" "1"
  chk "idle1 PASS model=m2" "$(job_out idle1 | grep -c 'PASS model=m2$')" "1"

  busy_failed="${busy_failed/"$case "/}"
  if [ "$fail" = 0 ]; then echo "PASS [$case]"; else
    busy_failed="${busy_failed:-}$case "
    { echo "--- [$case] trace ---"; cat "$TRACE"; echo "--- [$case] run.out ---"; cat "$T/run.out"; } >"$busy_dump/$case"
  fi
  return "$fail"
}

case "${BUSY_CASE:-}" in
  "") cases="stall spin" ;;
  stall|spin) cases="$BUSY_CASE" ;;
  *) echo "FAIL 未知的 BUSY_CASE='$BUSY_CASE'（只認 stall／spin）"; exit 2 ;;
esac
unset BUSY_CASE  # 環境裡殘留就把兩種案例都跑掉（並行驗收會帶 BUSY_CASE=spin）

# 失敗證據緩存在 mktemp 目錄；EXIT trap 統一清理（trap 字串不直接引用可能消失的變數）。
busy_dump="$(mktemp -d)"
busy_failed=""
finish() { local rc="$?"; set +u; [ -z "$busy_failed" ] || echo "--- 失敗案例：$busy_failed"; rm -rf "$T" "$busy_dump"; exit "$rc"; }
trap finish EXIT
bad=0
for c in $cases; do
  # 逐案例跑完，不讓後面的成功蓋掉前面失敗
  busy_case "$c" || bad=1
done
for c in $cases; do cat "$busy_dump/$c" 2>/dev/null; done
[ "$bad" = 0 ] && echo PASS
exit $bad
