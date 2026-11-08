#!/usr/bin/env bash
# issue #23：DCQ_MODELS 在 dcq add 時逐單寫進工單；沒帶 DCQ_MODELS 的 runner 跑這張只用那份清單，
# 沒帶的單照預設池。假 dc，只記 DC_FREE_MODEL／DC_MODEL，不打上游。
set -u
. "$(dirname "$0")/env.sh"
R="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DCQ_HOME="$T/q" DC_BIN="$T/bin" PATH="$T/bin:$PATH"
export DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1 DCQ_AUTORANK=0 DCQ_POOLSYNC=0 DCQ_GO_STATE="$T/none.json"
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json" DCQ_FREE_ROUNDS=1 DCQ_ORDER=default
export DCQ_POOL_GO="" DCQ_POOL_TAIL="" DCQ_POOL_PAID="" DCQ_POOL_ZEN="aa bb cc"
unset DCQ_MODELS DCQ_PREFER DCQ_ALLOW_API
mkdir -p "$T/bin" "$T/w1" "$T/w2"
cat > "$T/bin/dc" <<'EOF'
#!/usr/bin/env bash
case "$1" in *hard*) echo "$(basename "$1" .md) ${DC_FREE_MODEL}${DC_MODEL:+/DC_MODEL=$DC_MODEL}" >> "$TRACE"; exit 0 ;; esac
echo "$(basename "$1" .md) ${DC_FREE_MODEL}${DC_MODEL:+/DC_MODEL=$DC_MODEL}" >> "$TRACE"
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
chk "沒帶的單照預設池" "$(grep '^p ' "$TRACE" | cut -d' ' -f2 | tr '\n' ' ')" "aa "

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

[ "$fail" = 0 ] || { echo "--- run ---"; cat "$T/run.out"; echo "--- run2 ---"; cat "$T/run2.out"; }
[ "$fail" = 0 ] && echo PASS
exit "$fail"
