#!/usr/bin/env bash
# dcq 自動重排自檢：假 gaps.tsv 驗三條規則
# 1) 停滯率 ≥30% 的合格模型降到最後  2) 合格者在自己的位置裡依「每 PASS 秒數」重排（等待時間算進去）
# 3) 樣本不足的留在手排位置；rc=2 不算樣本；DCQ_AUTORANK=0 照手排
set -u
. "$(dirname "$0")/env.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"   # 不讀真的全域閘（10-19：Jev 閘封鎖時這些測試全掛）
export DCQ_HOME="$T/q"; mkdir -p "$DCQ_HOME/logs"
export DCQ_RANK_PRIOR_K=0   # 下面 1)–9) 驗原始 s/pass 規則；平滑另在 10) 驗
G="$DCQ_HOME/logs/gaps.tsv"; D="$(date +%F)_00:00:00"
row() { printf '%s\t%s\t10\t%s\t%s\n' "$D" "$1" "$2" "$3" >> "$G"; }
rep() { local i; for i in $(seq "$1"); do row "$2" "$3" "$4"; done; }
rowd() { printf '%s\t%s\t10\t%s\texit\t%s\n' "$D" "$1" "$2" "$3" >> "$G"; }
rep 10 a 0 exit            # a：100%
rep 5 b 0 exit; rep 5 b 1 exit   # b：50%
rep 6 c 0 exit; rep 4 c 143 stall # c：停滯 40% → 降級
rep 2 d 1 exit             # d：樣本不足（<RANK_ZERO_N=3，不觸發 0 PASS 短路），留原位
rep 9 e 0 exit; rep 5 e 2 exit    # e：扣掉 rc=2 只剩 9 筆 → 不合格
for i in $(seq 10); do rowd f 0 300; done                         # f：100% 但每張 300s → 300 s/pass
for i in $(seq 6); do rowd g 0 30; done; for i in $(seq 4); do rowd g 1 30; done  # g：60%、每張 30s → 50 s/pass
fail=0
got="$(DCQ_MODELS= DCQ_POOL_ZEN="c b d a e f g" DCQ_POOL_GO="" dcq rank | sed -n 's/^順序：//p')"
want="a d b e g f"   # g 通過率較低但等得少，排在 f 前；c 停滯 40% 進懲罰層
pen="$(DCQ_MODELS= DCQ_POOL_ZEN="c b d a e f g" DCQ_POOL_GO="" dcq rank | sed -n 's/^懲罰層（免費層之後）：//p')"
[ "$pen" = "c" ] || { echo "FAIL pen: got [$pen] want [c]"; fail=1; }
[ "$got" = "$want" ] || { echo "FAIL order: got [$got] want [$want]"; fail=1; }
got="$(DCQ_AUTORANK=0 DCQ_POOL_ZEN="c b d a e" DCQ_POOL_GO="" dcq status 2>&1 | awk '/busy=/{printf "%s ", $1}')"
case "$got" in "c b d a e "*) ;; *) echo "FAIL autorank=0: [$got]"; fail=1 ;; esac
# 4) 每日探測（probe.tsv 最新一批）：非 OK 的移到最後；manual 位置依探測秒數排；舊批次（>8 天）不算
P="$DCQ_HOME/logs/probe.tsv"; now="$(date +%F_%T)"; old="$(date -v-9d +%F_%T 2>/dev/null || date -d '-9 days' +%F_%T)"
printf '%s\topencode\tx\tOK\t50\n%s\topencode\ty\tOK\t5\n%s\topencode\tz\tOK\t9\n' "$old" "$old" "$old" > "$P"
printf '%s\topencode\tx\tOK\t9\n%s\topencode\ty\tTIMEOUT\t60\n%s\topencode-go\ty\tFAIL\t1\n%s\topencode\tw\tOK\t3\n' "$now" "$now" "$now" "$now" >> "$P"
got="$(DCQ_MODELS= DCQ_POOL_ZEN="a x y z w" DCQ_POOL_GO="" dcq rank | sed -n 's/^順序：//p')"
want="a w x z y"   # y 最新一批全掛→最後；w 3s 先於 x 9s；z 只有舊批次＝無資料，排在有資料的後面
[ "$got" = "$want" ] || { echo "FAIL probe: got [$got] want [$want]"; fail=1; }
: > "$P"; printf '%s\topencode\ty\tTIMEOUT\t60\n' "$old" > "$P"   # 只有過期批次 → 不降級
got="$(DCQ_MODELS= DCQ_POOL_ZEN="y a" DCQ_POOL_GO="" dcq rank | sed -n 's/^順序：//p')"
[ "$got" = "y a" ] || { echo "FAIL stale probe: got [$got] want [y a]"; fail=1; }
wk="$(date -v-5d +%F_%T 2>/dev/null || date -d '-5 days' +%F_%T)"   # 週探測：5 天前的批次仍要採用
: > "$P"; printf '%s\topencode\ty\tTIMEOUT\t60\n' "$wk" > "$P"
got="$(DCQ_MODELS= DCQ_POOL_ZEN="y a" DCQ_POOL_GO="" dcq rank | sed -n 's/^順序：//p')"
[ "$got" = "a y" ] || { echo "FAIL weekly probe: got [$got] want [a y]"; fail=1; }
# 5) 假釋：累犯最近一筆 >7 天 → 回免費層 manual；7 天內 → 留冷宮（0 PASS，2026-10-22 起不放懲罰層）
: > "$P"; old="$(date -v-10d +%F 2>/dev/null || date -d '-10 days' +%F)_00:00:00"
for i in 1 2 3; do printf '%s\th\t10\t1\texit\n' "$old" >> "$G"; printf '%s\tk\t10\t1\texit\n' "$D" >> "$G"; done
out="$(DCQ_MODELS= DCQ_POOL_ZEN="h k a" DCQ_POOL_GO="" dcq rank)"
got="$(printf '%s\n' "$out" | sed -n 's/^順序：//p')"; pen="$(printf '%s\n' "$out" | sed -n 's/^冷宮（兜底層之後、訂閱層之前）：//p')"
[ "$got" = "h a" ] && [ "$pen" = "k" ] || { echo "FAIL parole: got [$got | $pen] want [h a | k]"; fail=1; }
# 6) 合格（ranked）但探測掛掉的模型：只能出現一次、排最後，不得佔走另一隻合格者的位置
#    （2026-10-13 實例：nemotron probe-down 又留在 ranked 名單，順序變 "nemotron mimo ling nemotron"，93% 的 space-bunny 消失）
: > "$G"; : > "$P"
for i in $(seq 10); do rowd r1 0 100; rowd r2 0 110; done
printf '%s\topencode\tr1\tTIMEOUT\t60\n%s\topencode\tr2\tOK\t3\n' "$now" "$now" > "$P"
got="$(DCQ_MODELS= DCQ_POOL_ZEN="r1 r2 m" DCQ_POOL_GO="" dcq rank | sed -n 's/^順序：//p')"
[ "$got" = "r2 m r1" ] || { echo "FAIL ranked+probe-down: got [$got] want [r2 m r1]"; fail=1; }
# 7) 名單同步：改名（舊名 GONE＋新名 OK）→ 舊名移出、新名接進；SKIP 的不收；別家 provider 的列不算
: > "$G"; export DCQ_GO_STATE="$T/none.json"
printf '%s\topencode\told\tGONE\t0\n%s\topencode\tnew\tOK\t3\n%s\topencode\tskipme\tOK\t2\n%s\topencode-go\tother\tOK\t1\n%s\topencode\ta\tOK\t5\n' "$now" "$now" "$now" "$now" "$now" > "$P"
out="$(DCQ_MODELS= DCQ_POOL_ZEN="old a" DCQ_POOL_GO="" DCQ_POOL_SKIP="skipme" dcq rank)"
got="$(printf '%s\n' "$out" | sed -n 's/^順序：//p')"; note="$(printf '%s\n' "$out" | sed -n 's/^名單同步：//p')"
[ "$got" = "new a" ] || { echo "FAIL sync order: got [$got] want [new a]"; fail=1; }
[ "$note" = "新增 new；移出 old；" ] || { echo "FAIL sync note: [$note]"; fail=1; }
got="$(DCQ_POOLSYNC=0 DCQ_MODELS= DCQ_POOL_ZEN="old a" DCQ_POOL_GO="" dcq rank | sed -n 's/^順序：//p')"
case " $got " in *" old "*) ;; *) echo "FAIL POOLSYNC=0 still synced: [$got]"; fail=1 ;; esac
# 7b) x-pool.tsv（推文讀出的改名）比探測新就蓋過探測；比探測舊的不採用
X="$(dirname "$P")/x-pool.tsv"
later="$(date -v+1M +%F_%T 2>/dev/null || date -d '+1 min' +%F_%T)"; earlier="2000-01-01_00:00:00"
printf '%s\topencode\tbun\tOK\t3\n%s\topencode\ta\tOK\t5\n' "$now" "$now" > "$P"
printf '%s\t1\tGONE\tbun\n%s\t1\tNEW\tmm\n%s\t2\tGONE\ta\n' "$later" "$later" "$earlier" > "$X"
out="$(DCQ_MODELS= DCQ_POOL_ZEN="bun a" DCQ_POOL_GO="" dcq rank)"
note="$(printf '%s\n' "$out" | sed -n 's/^名單同步：//p')"
[ "$note" = "新增 mm；移出 bun；" ] || { echo "FAIL x-pool note: [$note]"; fail=1; }
rm -f "$X"
# 8) QUOTA（額度用完，06:00 探測常見）不判 down
printf '%s\topencode\tq\tQUOTA\t1\n%s\topencode\ta\tOK\t5\n' "$now" "$now" > "$P"
got="$(DCQ_MODELS= DCQ_POOL_ZEN="q a" DCQ_POOL_GO="" dcq rank)"
case "$got" in *"probe-down"*) echo "FAIL quota judged down"; fail=1 ;; esac
# 9) 訂閱層同步：upstream 沒有的移出；first_seen 非 base 的非 -free 新模型接尾；base 的不收；過期 state 不採用
: > "$P"
printf '{"at":"%s","upstream":["g1","g3","old1","newm","newf-free"],"first_seen":{"g1":"base","g3":"base","old1":"base","newm":"2026-10-15","newf-free":"2026-10-15"}}' "$(date +%FT%T)" > "$DCQ_GO_STATE"
got="$(DCQ_MODELS= DCQ_POOL_ZEN="a" DCQ_POOL_GO="" DCQ_POOL_PAID="opencode-go/g1 opencode-go/g2 opencode-go/g3" dcq rank | sed -n 's/^訂閱層：//p')"
[ "$got" = "opencode-go/g1 opencode-go/g3 opencode-go/newm" ] || { echo "FAIL paid sync: [$got]"; fail=1; }
printf '{"at":"2000-01-01T00:00:00","upstream":["g1"]}' > "$DCQ_GO_STATE"
got="$(DCQ_MODELS= DCQ_POOL_ZEN="a" DCQ_POOL_GO="" DCQ_POOL_PAID="opencode-go/g1 opencode-go/g2" dcq rank | sed -n 's/^訂閱層：//p')"
[ "$got" = "opencode-go/g1 opencode-go/g2" ] || { echo "FAIL stale go state: [$got]"; fail=1; }
# omniroute/* 要在 opencode.json 宣告才留池（fit_pool）；這段只驗 Go 免費同步，給一份宣告 nim-pool 的設定、略過健康檢查
mkdir -p "$T/cfg/opencode"; echo '{"provider":{"omniroute":{"models":{"nim-pool":{}}}}}' > "$T/cfg/opencode/opencode.json"
export XDG_CONFIG_HOME="$T/cfg" DCQ_OR_HC=0
# Go 免費同步：兜底層 upstream 沒有的 opencode-go/*-free 移出、新 -free 接 opencode-go 段尾；omniroute/* 不動
printf '{"at":"%s","upstream":["f1-free","newf-free","oldf-free"],"first_seen":{"f1-free":"base","oldf-free":"base","newf-free":"2026-10-15"}}' "$(date +%FT%T)" > "$DCQ_GO_STATE"
got="$(DCQ_MODELS= DCQ_POOL_ZEN="a" DCQ_POOL_GO="" DCQ_POOL_PAID="" DCQ_POOL_TAIL="opencode-go/f1-free opencode-go/gone-free omniroute/nim-pool" dcq rank | sed -n 's/^兜底層：//p')"
[ "$got" = "opencode-go/f1-free opencode-go/newf-free omniroute/nim-pool" ] || { echo "FAIL go free sync: [$got]"; fail=1; }
got="$(DCQ_MODELS= DCQ_POOL_ZEN="a" DCQ_POOL_GO="" DCQ_POOL_PAID="" DCQ_POOL_TAIL="opencode-go/gone-free" dcq rank | sed -n 's/^兜底層：//p')"
[ "$got" = "opencode-go/newf-free" ] || { echo "FAIL go free sync replace: [$got]"; fail=1; }
# 週掃：5 天前的 state 仍採用，9 天前的不採用（有效期 8 天）
printf '{"at":"%s","upstream":["g1"]}' "$(date -v-120H +%FT%T 2>/dev/null || date -d '-120 hours' +%FT%T)" > "$DCQ_GO_STATE"
got="$(DCQ_MODELS= DCQ_POOL_ZEN="a" DCQ_POOL_GO="" DCQ_POOL_PAID="opencode-go/g1 opencode-go/g2" dcq rank | sed -n 's/^訂閱層：//p')"
[ "$got" = "opencode-go/g1" ] || { echo "FAIL 5-day go state not adopted: [$got]"; fail=1; }
printf '{"at":"%s","upstream":["g1"]}' "$(date -v-216H +%FT%T 2>/dev/null || date -d '-216 hours' +%FT%T)" > "$DCQ_GO_STATE"
got="$(DCQ_MODELS= DCQ_POOL_ZEN="a" DCQ_POOL_GO="" DCQ_POOL_PAID="opencode-go/g1 opencode-go/g2" dcq rank | sed -n 's/^訂閱層：//p')"
[ "$got" = "opencode-go/g1 opencode-go/g2" ] || { echo "FAIL 9-day go state adopted: [$got]"; fail=1; }
# 10) 上游不回：why=upstream 不算模型樣本（5 筆 upstream 不觸發 0 PASS 短路）；5 筆 stall 照樣觸發
: > "$G"; rep 5 u 124 upstream; rep 5 s 124 stall
out="$(DCQ_MODELS= DCQ_POOL_ZEN="u s a" DCQ_POOL_GO="" dcq rank)"
pen="$(printf '%s\n' "$out" | sed -n 's/^冷宮（兜底層之後、訂閱層之前）：//p')"
[ "$pen" = "s" ] || { echo "FAIL upstream counted as model fault: zero=[$pen] want [s]"; fail=1; }
# 11) zero_output 分類：全 0 輸出且無 part＝上游不回；有工具 part 或有輸出＝模型卡住
eval "$(sed -n '/^zero_output()/,/^}/p' "$(command -v dcq)")"
printf '{"messages":[{"info":{"role":"user"},"parts":[{"type":"text"}]},{"info":{"role":"assistant","tokens":{"output":0}},"parts":[]}]}' > "$T/z1.json"
printf '{"messages":[{"info":{"role":"assistant","tokens":{"output":0}},"parts":[{"type":"tool"}]}]}' > "$T/z2.json"
printf '{"messages":[{"info":{"role":"assistant","tokens":{"output":0}},"parts":[]},{"info":{"role":"assistant","tokens":{"output":12}},"parts":[]}]}' > "$T/z3.json"
zero_output "$T/z1.json" || { echo "FAIL zero_output z1 should be upstream"; fail=1; }
if zero_output "$T/z2.json"; then echo "FAIL zero_output z2 has tool part"; fail=1; fi
if zero_output "$T/z3.json"; then echo "FAIL zero_output z3 has output"; fail=1; fi
# 12) upstream 一次就冷卻 UPSTREAM_COOL_S；一般 stall 的 bump_fail 第一次不冷卻
eval "$(sed -n -e '/^now()/p' -e '/^fk()/p' -e '/^ZEN_GATE=/p' -e '/^cool_left()/,/^}/p' -e '/^reset_fail()/p' -e '/^UPSTREAM_COOL_S=/p' -e '/^cool_upstream()/,/^}/p' -e '/^bump_fail()/,/^}/p' "$(command -v dcq)")"
ZG="$(dirname "$(readlink -f "$(command -v dcq)")")/zen-gate"   # dcq 裡的 ZG 用 $0，eval 進來會指到 test/
Q="$DCQ_HOME"; ALLOW=2; COOL_S=120; mkdir -p "$Q/.health"
cool_upstream "opencode/u1" 2>/dev/null; left=$(cool_left "opencode/u1")
[ "$left" -ge 890 ] && [ "$left" -le 900 ] || { echo "FAIL cool_upstream left=$left want ~900"; fail=1; }
bump_fail "s1" 2>/dev/null; left=$(cool_left "s1")
[ "$left" = 0 ] || { echo "FAIL bump_fail cooled on first fail: $left"; fail=1; }
# 13) 兜底層與訂閱層的層內排序（2026-10-21）：規則與免費層相同；只在層內排，不跨層、不分難度
: > "$G"; : > "$P"
export DCQ_GO_STATE="$T/none2.json"      # 不採用 go-sync state（它會改兜底／訂閱層清單）
rep 8 x/hi 0 exit; rep 2 x/hi 1 exit      # x/hi：10 跑 8 過
rep 2 x/lo 0 exit; rep 8 x/lo 1 exit      # x/lo：10 跑 2 過
rep 3 x/z 1 exit                          # x/z：3 跑 0 過 → 0 PASS 短路，降到該層最後
T1="x/z x/lo x/hi"
got="$(DCQ_MODELS= DCQ_POOL_ZEN="a" DCQ_POOL_TAIL="$T1" DCQ_POOL_PAID="" dcq rank | sed -n 's/^兜底層：//p')"
[ "$got" = "x/hi x/lo x/z" ] || { echo "FAIL tail rank: got [$got] want [x/hi x/lo x/z]"; fail=1; }
got="$(DCQ_MODELS= DCQ_POOL_ZEN="a" DCQ_POOL_TAIL="" DCQ_POOL_PAID="$T1" dcq rank | sed -n 's/^訂閱層：//p')"
[ "$got" = "x/hi x/lo x/z" ] || { echo "FAIL paid rank: got [$got] want [x/hi x/lo x/z]"; fail=1; }
got="$(DCQ_AUTORANK=0 DCQ_POOL_ZEN="a" DCQ_POOL_TAIL="$T1" DCQ_POOL_PAID="" dcq rank | sed -n 's/^兜底層：//p')"
[ "$got" = "$T1" ] || { echo "FAIL tail autorank=0: got [$got] want [$T1]"; fail=1; }
# 耗時反例：x/fast 10 跑 6 過（每筆 30s）vs x/slow 10 跑 10 過（每筆 300s）→ 排的是每 PASS 秒數，不是通過率
: > "$G"
for i in $(seq 6); do rowd x/fast 0 30; done
for i in $(seq 4); do rowd x/fast 1 30; done
for i in $(seq 10); do rowd x/slow 0 300; done
got="$(DCQ_MODELS= DCQ_POOL_ZEN="a" DCQ_POOL_TAIL="x/slow x/fast" DCQ_POOL_PAID="" dcq rank | sed -n 's/^兜底層：//p')"
[ "$got" = "x/fast x/slow" ] || { echo "FAIL tail s/pass: got [$got] want [x/fast x/slow]"; fail=1; }
# DCQ_MODELS 有設 → 不排序（照 DCQ_POOL_TAIL 原順序）
got="$(DCQ_MODELS="m1" DCQ_POOL_ZEN="a" DCQ_POOL_TAIL="$T1" DCQ_POOL_PAID="" dcq rank | sed -n 's/^兜底層：//p')"
[ "$got" = "$T1" ] || { echo "FAIL tail DCQ_MODELS: got [$got] want [$T1]"; fail=1; }
# 12) 2026-10-22 智慧加權：貝氏平滑＋0 PASS 進冷宮＋探測過時＋Go 免費併入主免費層
#  拿掉任一項修正，這段都會 FAIL：
#  - 平滑：gb 4 跑 3 過、每張 60s（原始 80 s/pass）vs mm 30 跑 17 過、每張 300s（原始 529）；樣本不足時舊版 gb 留手排位置
#  - 冷宮：zz 4 跑 0 過不得出現在懲罰層
#  - 探測過時：dd 探測 down，但探測之後有 PASS → 不得被當 probe-down 排到最後
: > "$G"; : > "$P"
old2="$(date -v-2d +%F 2>/dev/null || date -d '-2 days' +%F)_00:00:00"
printf '%s\topencode\tdd\tTIMEOUT\t60\n' "$old2" > "$P"
for i in $(seq 17); do rowd mm 0 300; done; for i in $(seq 13); do printf '%s\tmm\t200\t143\tstall\t300\n' "$D" >> "$G"; done
for i in 1 2 3; do rowd opencode-go/gb-free 0 60; done; rowd opencode-go/gb-free 1 60
for i in 1 2 3 4; do rowd zz 1 200; done
for i in 1 2 3; do rowd dd 0 150; done; rowd dd 1 150
CAT2="$T/cat2"; mkdir -p "$CAT2"
printf 'free\topencode-run\topencode/mm\tok\t-\t-\tmm\tany\nfree\topencode-run\topencode/zz\tok\t-\t-\tzz\tany\nfree\topencode-run\topencode/dd\tok\t-\t-\tdd\tany\nfree\topencode-run\topencode-go/gb-free\tok\t-\t-\topencode-go/gb-free\tany\nfree\tomniroute\tor\tok\t-\t-\tx/or\teasy-only\n' > "$CAT2/models.tsv"
out="$(env -u DCQ_POOL_ZEN -u DCQ_POOL_TAIL DCQ_RANK_PRIOR_K=2 DCQ_CATALOG="$CAT2" DCQ_MODELS= DCQ_POOL_GO="" DCQ_POOL_PAID="" dcq rank)"
got="$(printf '%s\n' "$out" | sed -n 's/^順序：//p')"
zero="$(printf '%s\n' "$out" | sed -n 's/^冷宮（兜底層之後、訂閱層之前）：//p')"
pen="$(printf '%s\n' "$out" | sed -n 's/^懲罰層（免費層之後）：//p')"
tailx="$(printf '%s\n' "$out" | sed -n 's/^兜底層：//p')"
[ "$got" = "opencode-go/gb-free dd" ] || { echo "FAIL smooth/gofree order: got [$got] want [opencode-go/gb-free dd]"; fail=1; }
[ "$zero" = "zz" ] || { echo "FAIL zero pool: got [$zero] want [zz]"; fail=1; }
[ "$pen" = "mm" ] || { echo "FAIL pen keeps demoted only: got [$pen] want [mm]"; fail=1; }
[ "$tailx" = "x/or" ] || { echo "FAIL tail after gofree move: got [$tailx] want [x/or]"; fail=1; }
printf '%s\n' "$out" | grep -q '^dd .* stale ' || { echo "FAIL stale probe tag: $(printf '%s\n' "$out" | grep '^dd ')"; fail=1; }
printf '%s\n' "$out" | grep -q '^mid 不派：x/or$' || { echo "FAIL easy-only: $(printf '%s\n' "$out" | grep '不派')"; fail=1; }
# DCQ_GOFREE_MAIN=0 → Go 免費留在兜底層
tailx="$(env -u DCQ_POOL_ZEN -u DCQ_POOL_TAIL DCQ_GOFREE_MAIN=0 DCQ_RANK_PRIOR_K=2 DCQ_CATALOG="$CAT2" DCQ_MODELS= DCQ_POOL_GO="" DCQ_POOL_PAID="" dcq rank | sed -n 's/^兜底層：//p')"
[ "$tailx" = "opencode-go/gb-free x/or" ] || { echo "FAIL GOFREE_MAIN=0: got [$tailx]"; fail=1; }
# 11) 全池故障不記單隻的帳（10-27）：同 10 分鐘有 ≥3 隻別的模型 quota／upstream／卡住，這次卡住當上游故障。
# 實例 10-25 03:58–05:13 Zen 全 quota、Go 訂閱全掛，opencode-go/beam-free 那段卡 8 次 → mid 停滯 80% 被降懲罰層。
#   hh：2 過＋8 卡，每次卡都撞全池故障 → 不降級；kk：同樣 2 過＋8 卡但單獨卡 → 照樣降級
: > "$G"; : > "$P"; dy="$(date +%F)"
for h in 01 02 03 04 05 06 07 08; do
  printf '%s_%s:00:00\thh\t200\t143\tstall\t300\n%s_%s:30:00\tkk\t200\t143\tstall\t300\n' "$dy" "$h" "$dy" "$h" >> "$G"
  for q in q1 q2 q3; do printf '%s_%s:01:00\t%s\t1\t1\tquota\t5\n' "$dy" "$h" "$q" >> "$G"; done
done
for m in hh hh kk kk; do rowd "$m" 0 60; done
pen="$(DCQ_MODELS= DCQ_POOL_ZEN="hh kk" DCQ_POOL_GO="" dcq rank | sed -n 's/^懲罰層（免費層之後）：//p')"
[ "$pen" = "kk" ] || { echo "FAIL outage stall: got pen [$pen] want [kk]"; fail=1; }
[ "$fail" = 0 ] && echo PASS
exit "$fail"
