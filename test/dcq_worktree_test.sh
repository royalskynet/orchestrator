#!/usr/bin/env bash
# dcq worktree 模式：同一個乾淨 git cwd 的多張工單各自在 git worktree 裡跑，不再序列（2026-10-22 使用者定「要併發」）。
# 假 dc 照工單裡的 WRITE= 絕對路徑寫檔並 sleep；不打上游。斷言：
#   1) 三張同 cwd 工單同時在跑（IN 全部出現後才有第一個 OUT），cwd 都在 $Q/.wt/ 下
#   2) 工單裡的絕對路徑被改寫到 worktree（10-08 教訓：模型照絕對路徑寫回主 checkout）
#   3) 不衝突的兩張 merge 回主 checkout（檔案在 main、MERGED=1）；worktree 與分支收掉
#   4) 同檔衝突的那張：MERGE=conflict、main 不受影響、分支保留
#   5) cwd 髒、或 DCQ_WORKTREE=0 → 照舊直接在 cwd 跑（序列路徑）
set -u
. "$(dirname "$0")/env.sh"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"   # macOS /var → /private/var，要和 git worktree list 印的一致
export DCQ_HOME="$T/q"; mkdir -p "$T/bin"
export DC_BIN="$T/bin" PATH="$T/bin:$PATH"
export DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"
export DCQ_FREE_ROUNDS=1 DCQ_POOL_PAID="" DCQ_POOL_TAIL="" DCQ_ORDER=default
export DCQ_PROV_MAX="zen=3"   # 裸模型名歸 zen，providers.tsv 預設上限 2 會卡第三張；這裡測的是 worktree 併發，不是 provider 上限
export TRACE="$T/trace"; : > "$TRACE"

# 假 dc：讀工單的 WRITE=<絕對路徑>（內容＝CONTENT=），寫檔，sleep 3 讓三張重疊
cat > "$T/bin/dc" <<'EOF'
#!/usr/bin/env bash
task="$1"; cwd="$2"; n="$(basename "$task" .md)"
w="$(sed -n 's/^WRITE=//p' "$task")"; c="$(sed -n 's/^CONTENT=//p' "$task")"
echo "IN $n $cwd $w $(date +%s)" >> "$TRACE"
say="$(sed -n 's/^SAYS=//p' "$task")"; [ -n "$say" ] && echo "$say" >&2
[ -n "$w" ] && printf '%s\n' "$c" > "$w"
sleep 3
echo "OUT $n $cwd $(date +%s)" >> "$TRACE"
exit 0
EOF
chmod +x "$T/bin/dc"
for g in deep-lint wo-verify; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$g"; chmod +x "$T/bin/$g"; done

mkrepo() { git init -q "$1"; git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init; }
mkrepo "$T/repo"
# a、b 寫不同檔；c 跟 a 寫同一個檔（add/add 衝突）
printf '# a\nWRITE=%s/out-a.txt\nCONTENT=a\n' "$T/repo" > "$T/a.md"
printf '# b\nWRITE=%s/out-b.txt\nCONTENT=b\n' "$T/repo" > "$T/b.md"
printf '# c\nWRITE=%s/out-a.txt\nCONTENT=c\n' "$T/repo" > "$T/c.md"
for n in a b c; do "$REPO/bin/dcq" add "$T/$n.md" "$T/repo" >/dev/null 2>&1 || echo "add failed: $n"; done
DCQ_MODELS="m1" DCQ_MODEL_MAX=3 "$REPO/bin/dcq" run -j 3 >"$T/run.out" 2>&1

fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }

# 1) 併發：第 3 個 IN 的時間 ≤ 第 1 個 OUT 的時間
in3="$(grep '^IN ' "$TRACE" | sed -n 3p | awk '{print $NF}')"; out1="$(grep '^OUT ' "$TRACE" | sed -n 1p | awk '{print $NF}')"
chk "三張同 cwd 工單重疊執行" "$([ -n "$in3" ] && [ -n "$out1" ] && [ "$in3" -le "$out1" ] && echo yes)" "yes"
chk "三張都在 .wt/ 下的 worktree 跑" "$(grep '^IN ' "$TRACE" | awk -v q="$DCQ_HOME/.wt/" 'index($3,q)==1' | wc -l | tr -d ' ')" "3"
# 2) 絕對路徑改寫
chk "工單 WRITE 絕對路徑改寫到 worktree" "$(grep '^IN ' "$TRACE" | awk -v q="$DCQ_HOME/.wt/" 'index($4,q)==1' | wc -l | tr -d ' ')" "3"
# 3) merge 回主 checkout
chk "b 的產物 merge 進 main" "$(cat "$T/repo/out-b.txt" 2>/dev/null)" "b"
chk "out-a.txt 進 main（a 或 c 其一）" "$([ -f "$T/repo/out-a.txt" ] && echo yes)" "yes"
chk "MERGED=1 兩張" "$(grep -l '^MERGED=1' "$DCQ_HOME"/done/*.job 2>/dev/null | wc -l | tr -d ' ')" "2"
# 4) 衝突那張
chk "MERGE=conflict 一張" "$(grep -l '^MERGE=conflict' "$DCQ_HOME"/done/*.job 2>/dev/null | wc -l | tr -d ' ')" "1"
chk "main 沒留下衝突標記" "$(git -C "$T/repo" status --porcelain | wc -l | tr -d ' ')" "0"
chk "衝突分支保留供人看" "$(git -C "$T/repo" branch --list 'dcq/*' | wc -l | tr -d ' ')" "1"
chk "worktree 全部收掉" "$(git -C "$T/repo" worktree list | wc -l | tr -d ' ')" "1"
chk "run.out 有衝突提示（status 也列）" "$(grep -c 'merge 衝突（PASS 但未合回' "$T/run.out")" "1"

# 5) 髒 cwd → 直接在 cwd 跑
: > "$TRACE"; mkrepo "$T/dirty"; echo x > "$T/dirty/untracked"
printf '# d\nWRITE=%s/out-d.txt\nCONTENT=d\n' "$T/dirty" > "$T/d.md"
"$REPO/bin/dcq" add "$T/d.md" "$T/dirty" >/dev/null 2>&1
DCQ_MODELS="m1" "$REPO/bin/dcq" run -j 2 >"$T/run2.out" 2>&1
chk "髒 cwd 走序列路徑（cwd 就是 repo）" "$(grep '^IN d ' "$TRACE" | awk '{print $3}')" "$T/dirty"
chk "髒 cwd 的 log 說明原因" "$(grep -q '序列' "$T/run2.out" && echo yes)" "yes"
# DCQ_WORKTREE=0 → 乾淨也直接跑
: > "$TRACE"; mkrepo "$T/off"
printf '# e\nWRITE=%s/out-e.txt\nCONTENT=e\n' "$T/off" > "$T/e.md"
"$REPO/bin/dcq" add "$T/e.md" "$T/off" >/dev/null 2>&1
DCQ_WORKTREE=0 DCQ_MODELS="m1" "$REPO/bin/dcq" run -j 2 >"$T/run3.out" 2>&1
chk "DCQ_WORKTREE=0 直接在 cwd 跑" "$(grep '^IN e ' "$TRACE" | awk '{print $3}')" "$T/off"
chk "DCQ_WORKTREE=0 沒開 worktree" "$(git -C "$T/off" worktree list | wc -l | tr -d ' ')" "1"

# 6) I3：dc 在 log 印 `dc: SCOPE=over` → job 檔記 SCOPE=over（只標記，工單仍 PASS）；沒印的不記
mkrepo "$T/sc"
printf '# s1\nSAYS=dc: SCOPE=over（改動超出工單 writes：x）： stray.txt\n' > "$T/s1.md"
printf '# s2\n' > "$T/s2.md"
for n in s1 s2; do "$REPO/bin/dcq" add "$T/$n.md" "$T/sc" >/dev/null 2>&1; done
DCQ_MODELS="m1" DCQ_MODEL_MAX=2 "$REPO/bin/dcq" run -j 2 >"$T/run4.out" 2>&1
chk "SCOPE=over 記進該張 job 檔" "$(grep -l '^SCOPE=over' "$DCQ_HOME"/done/*s1*.job 2>/dev/null | wc -l | tr -d ' ')" "1"
chk "沒印 SCOPE 的工單不記" "$(grep -l '^SCOPE=over' "$DCQ_HOME"/done/*s2*.job 2>/dev/null | wc -l | tr -d ' ')" "0"
chk "SCOPE=over 的工單仍 PASS（不判 FAIL）" "$(ls "$DCQ_HOME"/done/*s1*.job 2>/dev/null | wc -l | tr -d ' ')" "1"

[ "$fail" = 0 ] || { echo "--- run.out ---"; cat "$T/run.out"; echo "--- trace ---"; cat "$TRACE"; }
[ "$fail" = 0 ] && echo PASS
exit $fail
