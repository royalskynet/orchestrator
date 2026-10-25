#!/usr/bin/env bash
# zen-gate 的延遲倍增＋半開自檢：不打上游、不送 TG（PATH 前面放的是假 hpush）。
# 借鏡 OmniRoute 的 circuitBreaker（src/shared/utils/circuitBreaker.ts）：
# 連續 3 輪「到期→探測→又被封」才開始倍增（streak≤3 不變，>3 每輪 ×2），封頂 DC_ZEN_GATE_MAX_S。
# 閘檔、Jev 檔、JEN 計數檔全部指到暫存目錄，不碰本機真的閘。
set -u
. "$(dirname "$0")/env.sh"
R="$(cd "$(dirname "$0")/.." && pwd)"
ZG="$R/bin/zen-gate"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"
export DC_ZEN_GATE_S=100
export PATH="$T/bin:$PATH"
# 假 hpush：只記呼叫次數，真的不送 TG
printf '#!/bin/sh\necho x >> "%s/hpush.log"\n' "$T" > "$T/bin/hpush"; chmod +x "$T/bin/hpush"

fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
# 兩份閘取最大的到期時間
gate_until() { "$ZG" until; }
# 讓兩份閘都過期：trip 只在「呼叫當下閘是開的」才算新的一輪（兩份最大值 ≤ now）
expire() { echo $(( $(date +%s) - 5 )) > "$DC_ZEN_GATE"; rm -f "$JEV_ZEN_STATUS_FILE"; }
# |實際 − 期望| ≤ 容差
near() { local d=$(( $1 - $2 )); [ "$d" -lt 0 ] && d=$(( -d )); [ "$d" -le "$3" ] && echo y || echo n; }
streak() { cat "$DC_ZEN_GATE.streak" 2>/dev/null || echo 0; }
hp() { [ -f "$T/hpush.log" ] || { echo 0; return; }; wc -l < "$T/hpush.log" | tr -d ' '; }

# 1) 連續 5 輪：100／100／100／200／400（第 4 輪才開始倍增）
i=0
for want in 100 100 100 200 400; do
  i=$(( i + 1 ))
  expire
  u=$(DC_PUSH=1 "$ZG" trip "第 $i 輪")
  now=$(date +%s)
  chk "第 $i 輪封 $want 秒" "$(near "$u" "$(( now + want ))" 5)" y
  chk "第 $i 輪 streak=$i" "$(streak)" "$i"
done
chk "被封時有通知（假 hpush）" "$([ "$(hp)" -ge 1 ] && echo y || echo n)" y
# 閘檔是暫存路徑（非正式）且沒 DC_PUSH=1：不推播（10-21 模型手動 trip 5 次發出 5 則 TG 誤報）
n0=$(hp); expire; "$ZG" trip "暫存閘" >/dev/null
chk "暫存閘檔不推播" "$(hp)" "$n0"

# 2) 封頂：DC_ZEN_GATE_MAX_S=300 時第 5 輪只封 300（400 被砍）
"$ZG" ok >/dev/null 2>&1
i=0
for want in 100 100 100 200 300; do
  i=$(( i + 1 ))
  expire
  u=$(DC_ZEN_GATE_MAX_S=300 "$ZG" trip "第 $i 輪")
  now=$(date +%s)
  chk "封頂 300：第 $i 輪封 $want 秒" "$(near "$u" "$(( now + want ))" 5)" y
done
chk "封頂 300：streak 記到 5" "$(streak)" "5"

# 3) 閘還關著時重複 trip：不加計數、到期不變（同一場封鎖的重複回報）
keep_streak=$(streak)
future=$(( $(date +%s) + 10000 ))
echo "$future" > "$DC_ZEN_GATE"; rm -f "$JEV_ZEN_STATUS_FILE"
hp_before=$(hp)
"$ZG" trip "閘還關著" >/dev/null
chk "閘未到期：streak 不變" "$(streak)" "$keep_streak"
chk "閘未到期：到期不變" "$(cat "$DC_ZEN_GATE")" "$future"
chk "閘未到期：不再重複通知" "$(hp)" "$hp_before"

# 4) 半開：閘到期且還有被封紀錄 → 准探測；上游正常回應（ok）→ 計數歸零
expire
"$ZG" halfopen >/dev/null 2>&1; rc=$?
chk "閘到期且有 streak：halfopen exit 0" "$rc" "0"
"$ZG" ok >/dev/null 2>&1; rc=$?
chk "ok 回 0" "$rc" "0"
chk "ok 刪掉 streak 檔" "$([ -f "$DC_ZEN_GATE.streak" ] && echo yes || echo no)" "no"
"$ZG" halfopen >/dev/null 2>&1; rc=$?
chk "ok 之後：halfopen exit 1" "$rc" "1"
expire
u=$("$ZG" trip "ok 後第一輪")
now=$(date +%s)
chk "ok 之後下一次 trip 回到 100 秒" "$(near "$u" "$(( now + 100 ))" 5)" y
chk "ok 之後 streak 回到 1" "$(streak)" "1"

# 5) Jev 那份閘還在 → 兩份最大值 > now，半開不成立
expire
printf '{"ok":false,"blocked":true,"cooldown_until":%s}' "$(( ($(date +%s) + 600) * 1000 ))" > "$JEV_ZEN_STATUS_FILE"
"$ZG" halfopen >/dev/null 2>&1; rc=$?
chk "Jev 閘未到期：halfopen exit 1" "$rc" "1"
now=$(date +%s)
chk "until 取兩份最大值" "$(near "$(gate_until)" "$(( now + 600 ))" 5)" y
# Jev 閘未到期時 trip 也不算新一輪：streak 不加
keep_streak=$(streak)
"$ZG" trip "Jev 閘還在" >/dev/null
chk "Jev 閘未到期：streak 不加" "$(streak)" "$keep_streak"

exit "$fail"
