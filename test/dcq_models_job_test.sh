#!/usr/bin/env bash
# issue #23：DCQ_MODELS 在 dcq add 時逐單寫進工單；沒帶 DCQ_MODELS 的 runner 跑這張只用那份清單，
# 沒帶的單照預設池。假 dc，只記 DC_FREE_MODEL／DC_MODEL，不打上游。
set -u
. "$(dirname "$0")/env.sh"
R="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)" || exit 1; [ -d "$T" ] || exit 1; cd "$T" || exit 1
# 清理只碰 mktemp 拿到、非空、在暫存區、且不是 repo 的路徑（mktemp／cd 失敗時絕不 rm 到 repo）
trap '[ -n "$T" ] && [ -d "$T" ] && [ "$T" != "$R" ] && case "$T" in "${TMPDIR:-/tmp}"*|/tmp/*|/var/folders/*) rm -rf "$T" ;; esac' EXIT
export DCQ_HOME="$T/q" DC_BIN="$T/bin" PATH="$T/bin:$PATH"
export DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1 DCQ_AUTORANK=0 DCQ_POOLSYNC=0 DCQ_GO_STATE="$T/none.json"
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json" DCQ_FREE_ROUNDS=1 DCQ_ORDER=default
# zz 當 runner 的 DCQ_MODELS，好讓「沒帶的單照預設池」有別於後面的預設池
export DCQ_JOB_MAX=20  # 突變後也必須有界結束，不等正式冷卻週期。
export DCQ_POOL_GO="" DCQ_POOL_TAIL="" DCQ_POOL_PAID="" DCQ_POOL_ZEN="zz"
unset DCQ_MODELS DCQ_PREFER DCQ_ALLOW_API
mkdir -p "$T/bin" "$T/w1" "$T/w2"
cat > "$T/bin/dc" <<'EOF'
#!/usr/bin/env bash
# 工單會被快照成 $Q/.src/<id>/<原檔名>（11-09），案例名從內容 `# <name>` 取，不從檔名取
n="$(sed -n 's/^# //p' "$1" | head -n 1)"
echo "$n ${DC_FREE_MODEL}${DC_MODEL:+/DC_MODEL=$DC_MODEL}" >> "$TRACE"
[ "$n" != n ] || printf "candidate\n" > "$2/bon-result.txt"
case "$n" in f|g|odefault|ofree|cool) exit 1 ;; esac  # 失敗案例：f／g／o*；cool 用來把 aa 刷進冷卻
exit 0
EOF
chmod +x "$T/bin/dc"
for g in deep-lint wo-verify; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$g"; done
chmod +x "$T/bin/"*
export TRACE="$T/trace"; : > "$TRACE"
printf '# m\n' > "$T/m.md"; printf '# p\n' > "$T/p.md"

fail=0
chk() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: got '$2' want '$3'"; fail=1; fi; }

idm="$(DCQ_MODELS=codex/default "$R/bin/dcq" add "$T/m.md" "$T/w1" mid 2>/dev/null)"
chk "add 帶 DCQ_MODELS 寫進工單" "$(sed -n 's/^MODELS=//p' "$DCQ_HOME/pending/$idm.job")" "codex/default"
idp="$("$R/bin/dcq" add "$T/p.md" "$T/w2" mid 2>/dev/null)"
chk "沒帶不寫 MODELS=" "$(sed -n 's/^MODELS=//p' "$DCQ_HOME/pending/$idp.job")" ""


DCQ_ALLOWED_FAILS=9 "$R/bin/dcq" run -j 1 >"$T/run.out" 2>&1
chk "指定模型的單只用那份清單（不套 PREFER／各層）" "$(grep '^m ' "$TRACE" | cut -d' ' -f2 | tr '\n' ' ')" "codex/default "
chk "沒帶的單照預設池" "$(grep '^p ' "$TRACE" | cut -d' ' -f2 | tr '\n' ' ')" "zz "

# runner 自己的 DCQ_MODELS 行為不變：沒帶的單照 runner 的清單
: > "$TRACE"
idp2="$("$R/bin/dcq" add "$T/p.md" "$T/w2" mid 2>/dev/null)"
DCQ_MODELS="zz" "$R/bin/dcq" run -j 1 >"$T/run2.out" 2>&1
chk "runner 的 DCQ_MODELS 照舊管沒帶的單" "$(grep '^p ' "$TRACE" | cut -d' ' -f2 | tr '\n' ' ')" "zz "

# 逐單指定模型不套難度過濾：aa 是 fit=easy，hard 單點名 aa 照樣只用 aa（沒帶的 hard 單才剔 aa）
: > "$TRACE"
printf '# h\n' > "$T/h.md"
DCQ_MODELS=aa "$R/bin/dcq" add "$T/h.md" "$T/w1" hard >/dev/null 2>&1
DCQ_EASY_ONLY=aa DCQ_ALLOWED_FAILS=9 "$R/bin/dcq" run -j 1 >"$T/run3.out" 2>&1
chk "指定模型不套 fit=easy 過濾" "$(grep '^h ' "$TRACE" | cut -d' ' -f2 | tr '\n' ' ')" "aa "

# #23 補完（WO-F）：DCQ_ORDER=sub 時，指定模型全失敗也不換層（訂閱／免費／兜底池都有貨也不碰）
printf '# f\n' > "$T/f.md"
DCQ_MODELS=codex/default DCQ_ORDER=sub DCQ_PREFER=opencode-go "$R/bin/dcq" add "$T/f.md" "$T/w1" mid >/dev/null 2>&1
: > "$TRACE"
DCQ_POOL_PAID="opencode-go/g1" DCQ_POOL_TAIL="omniroute/t1" DCQ_POOL_CLAUDE="codex/default" \
  DCQ_ALLOWED_FAILS=9 "$R/bin/dcq" run -j 1 >"$T/run4.out" 2>&1
chk "指定模型全失敗不換層（只碰 codex/default）" "$(grep '^f ' "$TRACE" | cut -d' ' -f2 | tr '\n' ' ')" "codex/default "
chk "指定模型全失敗這張單落 failed" "$(ls "$DCQ_HOME/failed" 2>/dev/null | grep -c -- '-f\.job$')" "1"
chk "指定模型全失敗不記 PAID=1" "$(grep -c '^PAID=1' "$DCQ_HOME/failed/"*-f.job 2>/dev/null)" "0"

# WO-F2 §2：hard 單＋主免費層強模型全冷卻（原本會進 best-of-N，候選取自 runner 的 MODELS_hard）
# → 帶 MODELS= 的單不進 best-of-N，只碰清單內的模型，全失敗落 failed
: > "$TRACE"; : > "$DCQ_HOME"/failed/*.job 2>/dev/null; rm -f "$DCQ_HOME"/failed/*.job
mkdir -p "$T/repo"; git -C "$T/repo" init -q; git -C "$T/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
# 沒帶 MODELS= 的 hard 單（cwd 是乾淨 repo）：真的進了 best-of-N 的對照——它會叫到 bb
printf '# n\n' > "$T/n.md"
"$R/bin/dcq" add "$T/n.md" "$T/repo" hard >/dev/null 2>&1
mkdir -p "$DCQ_HOME/.health"
echo $(( $(date +%s) + 300 )) > "$DCQ_HOME/.health/zz.cool"
DCQ_EASY_ONLY="aa bb cc" DCQ_POOL_ZEN="zz aa bb cc" DCQ_PROV_MAX=zen=3 DCQ_ALLOWED_FAILS=9 "$R/bin/dcq" run -j 1 >"$T/run5.out" 2>&1
chk "對照 hard 實際進 best-of-N" "$(grep -l '^BON=' "$DCQ_HOME"/done/*-n.job 2>/dev/null | wc -l | tr -d ' ')" "1"
chk "對照 trace 只見候選模型" "$(grep '^n ' "$TRACE" | cut -d' ' -f2 | grep -Ev '^(aa|bb|cc)$' | wc -l | tr -d ' ')" "0"
chk "對照 trace 確有候選模型" "$(grep -qE '^n (aa|bb|cc)$' "$TRACE" && echo yes)" "yes"
# 指定 aa 的 hard 單一開始就遇到 COOL。保留 bb/cc 可供突變後的 best-of-N 逃出清單。
printf '# g\n' > "$T/g.md"
DCQ_MODELS=aa "$R/bin/dcq" add "$T/g.md" "$T/repo" hard >/dev/null 2>&1
until_time=$(( $(date +%s) + 3 ))
echo "$until_time" > "$DCQ_HOME/.health/aa.cool"
DCQ_EASY_ONLY="aa bb cc" DCQ_POOL_ZEN="zz aa bb cc" DCQ_PROV_MAX=zen=3 DCQ_ALLOWED_FAILS=9 "$R/bin/dcq" run -j 1 >"$T/run5g.out" 2>&1
chk "hard＋COOL＋指定模型只碰 aa" "$(grep '^g ' "$TRACE" | cut -d' ' -f2 | sort -u | tr '\n' ' ')" "aa "
chk "hard＋COOL＋指定模型落 failed" "$(ls "$DCQ_HOME"/failed/*-g.job 2>/dev/null | wc -l | tr -d ' ')" "1"
chk "hard＋COOL＋指定模型不記 BON" "$(grep -c '^BON=' "$DCQ_HOME"/failed/*-g.job 2>/dev/null)" "0"
rm -f "$DCQ_HOME/.health/zz.cool"

# ORDER=default／free：指定模型全失敗不換層（懲罰／兜底／訂閱池都有貨也不碰），落 failed，不記 PAID=1
for o in default free; do
  printf '# o%s\n' "$o" > "$T/o$o.md"
  DCQ_MODELS=codex/default DCQ_ORDER=$o "$R/bin/dcq" add "$T/o$o.md" "$T/w1" mid >/dev/null 2>&1
done
: > "$TRACE"
# opencode.json 未宣告的會被剔出池（run4 的 omniroute/t1 就沒進去）：用裸名當池，才會真的被叫到
DCQ_POOL_PAID="opencode-go/g1" DCQ_POOL_TAIL="zz" DCQ_POOL_CLAUDE="" DCQ_ALLOWED_FAILS=9 "$R/bin/dcq" run -j 1 >"$T/run6.out" 2>&1
for o in default free; do
  chk "ORDER=$o 指定模型全失敗不換層" "$(grep "^o$o " "$TRACE" | cut -d' ' -f2 | sort -u | tr '\n' ' ')" "codex/default "
  chk "ORDER=$o 指定模型全失敗落 failed" "$(ls "$DCQ_HOME"/failed/*-o"$o".job 2>/dev/null | wc -l | tr -d ' ')" "1"
  chk "ORDER=$o 指定模型全失敗不記 PAID=1" "$(grep -c '^PAID=1' "$DCQ_HOME/failed/"*-o"$o".job 2>/dev/null)" "0"
done

[ "$fail" = 0 ] || { echo "--- run ---"; cat "$T/run.out"; echo "--- run2 ---"; cat "$T/run2.out"; echo "--- run4 ---"; tail -20 "$T/run4.out"; echo "--- run5 ---"; tail -25 "$T/run5.out"; echo "--- run6 ---"; tail -25 "$T/run6.out"; }
[ "$fail" = 0 ] && echo PASS
exit "$fail"
