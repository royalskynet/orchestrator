#!/usr/bin/env bash
# dc 的 stdin 自檢：dc 啟動的 opencode run 的 stdin 必須已關（v1 非 TTY pipe 會等到 timeout，fix 11739/10324）。
# 做法（照 dc_upstream_test.sh 的假 opencode 慣例）：假的 opencode 在 [ -p /dev/stdin ] 時寫 STDIN_PIPE 進紀錄檔再 exit 9，
# 否則照 dc 要的最小行為（debug config＋ashes 一行 > agent）回成功。dc 以 `sleep 60 | dc …` 啟動——呼叫端stdin 是永遠不關的 pipe，
# dc 若沒在 exec 區塊把 stdin 關掉，假 opencode 會看到 /dev/stdin 是 pipe → 記 STDIN_PIPE → 測試 exit 1。
set -u
DC="${DC_BIN:-$(cd "$(dirname "$0")/.." && pwd)/bin/dc}"   # 先取：env.sh 會清掉所有 DC_* 變數（含 DC_BIN）
. "$(dirname "$0")/env.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/w" "$T/cfg/opencode"
export DCQ_HOME="$T/q" XDG_CONFIG_HOME="$T/cfg"
export DC_FREECHECK=off DC_NO_TIMEOUT_WARN=1 DC_NEGCTL=0 DC_SANDBOX=0
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"
export DC_OC_V2=0    # 假 opencode 不認 run --help 的 --pure 探測路徑也走同一支

cat > "$T/bin/opencode" <<X
#!/usr/bin/env bash
STDMARK="$T/stdin.mark"
case "\$1" in
  run) echo RAN >> "$T/ran.mark"; if [ -p /dev/stdin ]; then echo STDIN_PIPE >> "\$STDMARK"; exit 9; fi ;;
esac
case "\$1" in
  debug) echo '{"enabled_providers":["opencode"]}'; exit 0 ;;
esac
echo '> build · x'
echo done
X
chmod +x "$T/bin/opencode"
export PATH="$T/bin:$PATH"

# dc 用 bin/ 自帶的 wo-verify／deep-lint，工單要過 lint 才會走到 opencode run
printf '# t\n\n預期：exit 0\n\n## 驗收\n\n```bash\ntest -d /\n```\n' > "$T/t.md"

# PATH 最前放假 opencode；stdin 以「永不關的 pipe」餵進 dc
rc=0
sleep 60 | ( timeout 30 "$DC" "$T/t.md" "$T/w" >/dev/null 2>&1 ) || rc=$?

# 正向斷言：dc 真的跑到 opencode run（11-07：工單過不了 lint 時 dc 提早退出，舊版 dc 也會假 ok）
if [ ! -s "$T/ran.mark" ]; then
  echo "FAIL: dc 沒有執行到 opencode run（rc=${rc}），測試無效"
  exit 1
fi
if [ -s "$T/stdin.mark" ] || [ "$rc" = 124 ]; then
  echo "FAIL: opencode run 的 stdin 開著（mark=$(cat "$T/stdin.mark" 2>/dev/null), rc=${rc}）"
  exit 1
fi
echo ok
exit 0
