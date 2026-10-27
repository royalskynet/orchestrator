#!/usr/bin/env bash
# DCQ_PREFER（派o <名稱>）：名稱相符的免費模型先派，失敗後照原順序 fallback；沒設照原順序。假 dc，不打上游。
set -u
. "$(dirname "$0")/env.sh"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DCQ_HOME="$T/q"; mkdir -p "$T/bin"
export DC_BIN="$T/bin" PATH="$T/bin:$PATH"
export DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"
export DCQ_FREE_ROUNDS=1 DCQ_POOL_PAID="" DCQ_POOL_TAIL="" DCQ_ORDER=default
export TRACE="$T/trace"; : > "$TRACE"

# 每次嘗試都驗收失敗（rc 7）→ 換下一隻，TRACE 記下派的順序
cat > "$T/bin/dc" <<'EOF'
#!/usr/bin/env bash
echo "$(basename "$1" .md) $DC_FREE_MODEL" >> "$TRACE"
exit 7
EOF
chmod +x "$T/bin/dc"
for g in deep-lint wo-verify; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$g"; chmod +x "$T/bin/$g"; done

for n in pref plain; do mkdir -p "$T/$n"; printf '# %s\n' "$n" > "$T/$n.md"; done
DCQ_PREFER=DSX "$REPO/bin/dcq" add "$T/pref.md" "$T/pref" >/dev/null 2>&1 || echo "add failed: pref"
"$REPO/bin/dcq" add "$T/plain.md" "$T/plain" >/dev/null 2>&1 || echo "add failed: plain"
bad_rc=0; DCQ_PREFER='x;rm' "$REPO/bin/dcq" add "$T/plain.md" "$T/plain" >/dev/null 2>&1 || bad_rc=$?
DCQ_MODELS="m1 dsx-free m3 fp/a fp/dsx" DCQ_ALLOWED_FAILS=99 "$REPO/bin/dcq" run -j 1 >"$T/run.out" 2>&1

fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
chk "PREFER 相符的先派（跨 freepool、不分大小寫），其餘照原順序" "$(grep '^pref ' "$TRACE" | cut -d' ' -f2 | tr '\n' ' ')" "dsx-free fp/dsx m1 m3 fp/a "
chk "沒設 PREFER 照原順序" "$(grep '^plain ' "$TRACE" | cut -d' ' -f2 | tr '\n' ' ')" "m1 dsx-free m3 fp/a fp/dsx "
chk "PREFER 含非法字元拒絕入列" "$([ "$bad_rc" -ne 0 ] && echo rejected)" "rejected"
[ "$fail" = 0 ] || { echo "--- run.out ---"; cat "$T/run.out"; }
[ "$fail" = 0 ] && echo PASS
exit $fail
