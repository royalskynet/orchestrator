# Orchestrator

把你手上已知的各種 LLM 當成執行人，依實測表現智慧調配的工單調度器。一個任務檔進、機械驗收過的成果出。

- **模型來源不限 opencode**：Zen 免費池、opencode-go 訂閱、直連的 Kilo／NVIDIA NIM／Groq／Google AI Studio／OpenRouter 免費模型（不必裝 OmniRoute）、經 OmniRoute 轉接的供應商（選配）、付費 API，全部登記在 `catalog/models.tsv`，同一套階梯調度。opencode CLI 只當 agent 外殼（工具呼叫、檔案編輯）。
- **智慧加權**：每隻模型依 `gaps.tsv` 實績算「平均幾秒換到一次通過」，加貝氏平滑（樣本少的先拉向全池平均），層內自動重排。0 PASS 的進冷宮，停滯率高的進懲罰層。
- **多層 fallback**：免費 → 懲罰 → 兜底 → 冷宮 → 訂閱 → API（API 預設關）。觸發詞：派o＝免費優先、全敗升訂閱；派of＝只用免費；派os＝訂閱優先。
- **完成由腳本判定**：exit code＝工單自帶驗收腳本（`wo-verify`）的結果，不是模型自述。
- `dc` 派單張，`dcq` 併發跑多張（cwd 互斥、per-model 冷卻、停滯 watchdog、Zen 與 Go 免費額度分開計）。

這個 repo 是私有正本的脫敏鏡像，每週自動同步覆蓋。直接 push 到這裡的修補會在下次同步被倒回（issue #14）；同步腳本現在遇到這種 commit 會停推並告警，但修補仍要開 issue 或 PR，由維護者移植進正本。

舊名 dispatch-router（2026-10-22 改名）；底層指令 `dc`／`dcq` 不變。與 [`deep-agent`](https://github.com/royalskynet/deep-agent) 平行：deep 走 deepclaude 在沙箱外跑多步自主任務。

## Quick install／快速安裝

```bash
git clone https://github.com/royalskynet/orchestrator && cd orchestrator && ./install.sh
```

需求：macOS 或 Linux（Linux 下 `oc-probe` 的 launchd 排程不能用，模型名單要手動維護）、[opencode](https://opencode.ai) CLI；選配 [OmniRoute](https://github.com/cheaper-inference/OmniRoute) 接其他供應商。`install.sh` 只做使用者層級安裝：把 `dc`／`dcq`／`zen-gate` 連到 `~/.local/bin`、把 skill 連到 `~/.claude/skills/o`。

## English

**Orchestrator** dispatches work orders to whatever LLMs you already have access to, and picks among them by measured performance. One task file goes in; the work comes back only when a machine check says it is done.

- **Any model you can reach.** Zen free models, opencode-go subscription models, direct free providers (Kilo, NVIDIA NIM, Groq, Google AI Studio, OpenRouter — no OmniRoute needed), providers routed through an optional OmniRoute, and paid APIs are all listed in `catalog/models.tsv` and scheduled by the same ladder. The opencode CLI is used only as the agent harness (tool calls, file edits).
- **Weighted ranking.** Each model is scored by expected seconds per pass from its own run history (`gaps.tsv`), with a Bayesian prior that pulls low-sample models toward the pool mean. Models with zero passes move to a cold tier; models that stall often move to a penalty tier.
- **Tier ladder.** free → penalty → fallback → cold → subscription → API (API off by default). Order modes: `default` (free first, then subscription), `free` (free only), `sub` (subscription first).
- `dc <task.md> [cwd]` dispatches one work order. The exit code is the exit code of the task's own acceptance script (`wo-verify`), not the model's claim of success.
- Before dispatching, a lint gate refuses tasks without a runnable acceptance block, and a do-nothing control run rejects acceptance checks that would pass without any work.
- The acceptance script is pinned before the run; if the executor edits it, the run is judged as tampering (rc=3). Acceptance is re-run K times (default 2) to catch flaky results.
- `dcq` runs many work orders in parallel with per-directory locks, a model pool with per-model cooldown, and a stall watchdog. Zen free and Go free concurrency are counted separately.
- A second round on the free tier retries only models that failed upstream; a model that delivered work and failed acceptance is not retried on the same order.
- Model billing tiers are checked before each dispatch; paid models still run but trigger a Telegram warning.
- The watchdog does not kill an attempt while opencode has a tool subprocess running (usually a slow test), and `dc` raises opencode's bash tool timeout from 120 s to 300 s.
- `zen-gate` handles Zen free-tier IP blocks (including `FreeTierError` 403s): the block lasts 6 h for the first 3 consecutive rounds, then doubles each round up to 48 h. When it expires, one half-open probe decides whether to reopen.
- Telegram pushes fire only when state lives in the default paths (`~/.dcq`, `~/.jevgate`). Tests that point state at a temp directory stay silent unless `DC_PUSH=1`.

Formerly **dispatch-router** (renamed 2026-10-22); the `dc`/`dcq` commands are unchanged. Use plain `opencode run` if you only need a model to try something once.

The rest of this README is in Traditional Chinese.


## dc 到底比 `opencode run` 多什麼

只有這幾樣是真的多了東西，其餘都是把原生旗標設好預設值：

| # | 加了什麼 | 為什麼 opencode 自己做不到 |
|---|---|---|
| 1 | **exit code ＝ `wo-verify` 的 rc** | opencode 的 exit code 反映它自己有沒有跑完，不反映任務對不對。dc 把成敗綁在驗收腳本上。 |
| 2 | **派工前 `deep-lint` 閘** | 沒有可跑的驗收區塊就不派工 —— 否則模型做完也無法判定成敗。 |
| 3 | **計費分級警示** | 有 key 之後 `opencode models` 會列出付費模型；dc 把實際要派的模型分級，非免費照派但發 TG。 |
| 4 | **評分器釘住（`--pinned`，rc=3）** | 驗收區塊就在工單裡，執行人改得到的評分器他早晚會改到過關。派工前拍一份 pin，驗收跑 pin 並逐行比對；不一致即判篡改，不跑被改過的版本。dcq 換模型重試同一張時，沿用第一次留下的前置檢查憑證（`$DCQ_HOME/.preflight/<id>/pin`）：lint 與負向對照不重跑，評分器也不重抽，前一隻模型改過的驗收不會被釘成新基準（2026-10-21）。 |
| 5 | **do-nothing 負向對照（派工前，rc=2）** | 什麼都不做也會通過的驗收不是驗收。派工前先在同一 cwd 跑一次，此刻就過＝空包彈或 no-op，不派工。逃生門 `NEG-CONTROL: n/a`。 |
| 6 | **驗收重跑 K 次（`DC_VERIFY_K`，預設 2）** | 單次通過只代表「至少成功過一次」。重跑才抓得到時好時壞的驗收與副作用。 |

設好的預設（不是新能力，但沒有它們 dc 根本不會動）：

- **`--auto`**：`permission.bash="ask"` 在 headless 下會被自動拒絕 —— 沒這道模型**一跑 bash 就死**（連 `ls` 都過不了），只能靠 write/edit 硬寫。執行人本來就要能跑 bash，故預設開；`DC_NO_AUTO=1` 可關（會嚴重降能）。
- **`--pure`**：同模型 4.5s vs 16s（`agentpet.js` 外掛佔 ~11s）。opencode v2 移除了它，dc 看 `opencode run --help` 自動決定帶不帶。
- **`--standalone`（v2）**：v2 的 `run` 預設交給共用背景服務，服務卡死時 run 零輸出乾等；dc 在 v2 一律帶 `--standalone` 用私有 server，`--print-logs` 也要它才帶服務端 ERROR log。
- **cd 進工作目錄 + `-f`**：任務檔常在專案外，dc 先 cd 進工作目錄（1.18.x 另帶 `--dir`；v2 已移除），`-f` 附加任務檔。
- **message 放最前面**：`-f` 是陣列旗標，會把後續位置參數當附件路徑吞掉。
- **驗收在工作目錄底下跑**：驗收斷言用相對路徑，在呼叫端 cwd 跑會全部找不到檔案而誤判 FAIL。

**如果你只是要 opus 等級的模型跑一次、不在乎成敗由誰判定，直接用 `opencode run`。** dc 的價值在「完成」是機械判定的。

## 計費分級（不擋，非免費發 TG）

每次派工先把模型分成 free／sub（扣訂閱額度）／metered（按量計費，或沒查過的組合），跟 provider 無關。**全部照派**，非 free 一律先記 `~/.dcq/logs/billing.tsv`，再 `hpush` 發 TG 警示（背景送，TG 掛了不影響派工；`DC_TG_EVERY` 秒內只發一則，預設 600，下一則附被壓掉的筆數）。帳目錄不是 `~/.dcq/logs`（測試把 `DCQ_HOME` 指到暫存）就不推，`DC_PUSH=1` 強制推；`zen-gate`、`freecheck`、`oc-probe` 的推播同一規則：

- free：opencode 系（`opencode/`、`opencode-go/`）id 以 `-free` 結尾，加上明列的 `big-pickle`。
- 未指定模型時釘死 `space-bunny-free`（2026-10-09 起；此前是 longcat，19 跑 9 停滯故換掉。Go 版 space-bunny 已改付費，這裡走 Zen 的 `opencode/` 免費端點），**不吃 opencode config 的 per-agent 付費 model**。
- 別家路由器的組合名帶 `-free`（如 `omniroute/auto/best-free`）不算 free，成員沒逐一查過就當 metered。唯一查過的是 `omniroute/free-tools`：不經 opencode.ai 的兜底上游，成員 `big-pickle → agnes → openrouter/free` 逐一查過全免費（2026-10-02；nim-pool 實測卡 600s 已移出）。omniroute 的組合改了就要重查。key 由 dc 從 kv 注入。
- 「免費全敗才動用訂閱」的權重在 dcq 的模型池（見下），dc 只負責分級與警示。
- 白名單可用 `DC_FREE_EXTRA` 補。

有 key 的價值在免費模型這一側：Go 讓 `space-bunny-free`／`longcat-2.5-preview-free` 變 Unlimited、速率放寬；不在於把 dc 升級成付費執行器。

### `freecheck` —— 停止免費就終止並跳警報

**名字有 `-free` 不代表還免費。** Go 的免費是「限時」無限，時限到了 id 不會變、計費會變。所以名字比對只是第一層，真正的判準是額度：

`bin/freecheck` 在 `dc` 每次派 `opencode-go/*` 前、`dcq run` 開跑前各查一次 `https://opencode.ai/zen/go/v1/usage`（查的是 Go 帳號，Zen／kilo／nvidia 等不走 Go 的不查）：

| 判準 | 意思 |
|---|---|
| 任一窗 `status != ok` | Go 額度窗受限：exit 5，不寫 `.ALARM`。`dc` 回「上游額度用完」（dcq 記 why=quota、冷卻這隻），`dcq run` 只 WARN，其他免費模型照跑（2026-10-25 起；以前整隊停，Go 月額度一用完 of 全停） |
| 任一窗 `percent > 0` | 免費模型開始吃 Go 付費額度 |
| 要用的 Go 模型從 `/models` 消失 | 免費池收攤 |

警報動作：寫 `~/.dcq/.ALARM`、`hpush` 推播、`dc` 回 rc=2（fatal，不換模型重試，因為這是全域事實不是單一模型的問題）。`dcq` 一看到 `.ALARM` 就全隊停止收單，已在跑的那張讓它跑完（殺掉會留半套產物）。下一次 `dcq run` 會直接拒絕開跑，要人確認後刪掉 `.ALARM`。

`/models` 沒有價格欄位（只有 `id`／`object`／`created`／`owned_by`），所以只能從額度側判斷。已知天花板：**別處**（hermes、opencode TUI）用 Go 付費模型也會讓 `percent` 上升而誤報。寧可誤停不可誤花；確定是誤報就 `DC_FREECHECK=off`。

## 安裝

```bash
./install.sh
```

連結 `~/.local/bin/dc` 與 `~/.claude/skills/o`（opencode 與 Claude Code 都讀 `~/.claude/skills/`）。

**相依**：`wo-verify`、`deep-lint` 收在本 repo `bin/`，dc 直接用同目錄那份，不需要裝 `deep-agent`／deepclaude。`DC_BIN=<dir>` 只用來覆寫（測試注入假閘）。

另需 `jq`：`dc` 有 7 處要用，其中 `bin/dc:135` 靠它深度合併 `OPENCODE_CONFIG_CONTENT`。`dcq start` 另需 `tmux`（`bin/dcq:408` 直接 die）；`dcq run` 不用。

### Windows（git-bash）

`install.sh` 用 `ln -sfn`，Windows 沒有這個；`New-Item -ItemType SymbolicLink` 即使開了開發者模式也常要管理員權限。最省的做法是**跳過 symlink，直接把 `bin` 目錄加進 git-bash 的 `PATH`**（寫進 `~/.bashrc`，git-bash 會讀）：

```bash
export PATH="$HOME/.deepclaude/dispatch-router/bin:$PATH"
```

`dc`／`dcq`／`wo-verify`／`deep-lint` 都是 bash script，**Windows 上只能經 git-bash 執行**，PowerShell 直接打不會動。裝完先確認六支都在：

```bash
which dc dcq wo-verify deep-lint opencode jq
```

## 用法

```bash
dc <task.md> [cwd] [-- <opencode run 原生旗標>...]
```

- 任務檔路徑必須絕對。
- 契約（`deep-lint`／驗收 shell 區塊／「預期：」行／`## 禁止` 段）照 `deep` skill 的定義。
- `--agent <name>` 可指定 opencode agent 控制工具權限，模型仍由 dc 釘死。

環境變數：`DC_FREE_EXTRA`、`DC_FREE_MODEL`、`DC_SKIP_LINT=1`、`DC_BIN`、`DC_LOCK_WAIT`、`DC_NO_TIMEOUT_WARN=1`。
`DC_FREE_MODEL` 含 `/` 時當完整 `provider/model` 用，否則自動補 `opencode/` 前綴。

### cwd 互斥鎖在 `dc`，不只在 `dcq`

鎖只做在 `dcq` 的時代，直接呼叫 `dc` 可以完全繞過它 —— 兩個 session 對同一目錄派工，
產物互相覆蓋，只是運氣沒發生。所以鎖下沉到 `dc`：進入時對 cwd 取 `mkdir` 原子鎖，
路徑 `${DCQ_HOME:-~/.dcq}/.cwdlock/<cwd 的 shasum 前 12 碼>`，與 `dcq` **共用同一把**
（換個目錄名就等於兩把獨立的鎖，等於沒修）。

- 撞上別人持鎖：預設**不等**，`exit 75` 並印持鎖者 pid。`DC_LOCK_WAIT=<秒>` 才排隊。
- 持鎖者 pid 已死（`kill -9`、機器重開）：視為孤兒自動清掉再搶。
- `dcq` claim 時已持鎖，會帶 `DC_LOCK_HELD=1` 讓 `dc` 不重複拿（否則自己卡自己）。

### 上游停滯的 `chunkTimeout` WARN

opencode 對串流停滯的等待上限是 provider 的 `chunkTimeout`。5 分鐘預設值是 v1.18.27 才加的，
更舊的版本可能根本沒有上限 —— 上游一停滯就乾等，外觀等同卡死。`dc` 派工前唸一次合併後的 `opencode debug config`，
該 provider 沒設或設 > 180000 就 WARN。只出聲不擋：那是使用者的 config，`dc` 無權改。
建議在 `opencode.json` 設 `provider.<p>.options.chunkTimeout: 120000`。

**訂了 Go 之後**：`opencode-go/` provider 其實存在（29 個模型），只是本機 `opencode.json` 的 `enabled_providers` 白名單沒列它所以看不到。dc 遇到 `opencode-go/` 模型會用 `OPENCODE_CONFIG_CONTENT` 臨時把它加進白名單，不動使用者的 config；key 沿用 `opencode` 的憑證。免費的 `longcat`／`space-bunny` 掛在 `opencode/` 底下也能跑，兩條路都通（2026-10-02 實測）。

## Go lane 的 HTTP endpoint（`dc`／`dcq` 不走，但值得知道）

`https://opencode.ai/zen/go/v1/{chat/completions,messages,responses,models}` **對外可用**，訂閱就開。它跟被 `FreeTierError` 擋死的免費 Zen lane 是兩道完全不同的閘。2026-09-30 實測：

| | |
|---|---|
| 必要標頭 | `Authorization: Bearer <key>`、`x-opencode-session: ses_...`、**自訂 User-Agent**（文檔：`my-coding-agent/1.0` 這種，不要用 SDK 預設名） |
| 缺 session 標頭 | HTTP 400 `MissingSessionID` —— 只帶 Bearer 會以為「訂閱沒解鎖 API」，其實只是少一個標頭 |
| 模型 id | 線上用**裸 id**（`space-bunny-free`）。`opencode-go/space-bunny-free` 回 `Model is unavailable` —— 那個前綴是客戶端 config 的命名，不是 wire 上的 id |
| 目錄差異 | Go 的 `/models` 有 30 個，**不含 `big-pickle`**（Zen 專屬）。免費的兩隻：`space-bunny-free`、`longcat-2.5-preview-free` |
| prompt caching | **有**。回應帶 `prompt_tokens_details.cached_tokens`（實測 162 prompt 中 149 命中） |
| 併發 | 8 併發各帶自己的 session：全 200、每發約 1.5s、wall 2s，無 429 |
| 共用 session | 8 發共用同一個 `x-opencode-session` 會塞車（兩發拖到 8.3s／10.9s）。**session 是路由與快取的 key，一個並行單位配一個** |
| 對照組 | 同一把 key 打免費 Zen lane `/zen/v1` 仍是 403 `FreeTierError` |

但 HTTP 給的是推理不是 agent，改檔案仍得跑 CLI —— 所以 `dcq` 還是開 N 個 `dc` 進程，不打 HTTP。

### Hermes 已經內建 `opencode-go`，不用自己寫 shim

想把 Go lane 接到 Hermes 的話：**它內建就有**，上面那些標頭細節它都處理好了。2026-09-30 實測。

| | |
|---|---|
| provider | `hermes_cli/auth.py` 內建 `opencode-go`，base_url `https://opencode.ai/zen/go/v1`，env `OPENCODE_GO_API_KEY` |
| session 標頭 | `agent/opencode_affinity.py` 每發自動帶 `x-opencode-session`，沒有會話 id 時生 `oneshot-<hex>`。註解直接寫明是為了 Go lane 的 `MissingSessionID` 400，上游早修過同一個坑 |
| 快取親和 | session key 綁對話 root，compaction 後不變；壓縮／標題／vision 這些輔助呼叫共用同一顆 |
| 模型 id | `opencode-go` 屬 flat-namespace reseller，用裸 id，跟 wire 一致 |
| 目錄 | live-first，靠 `GET /models` 補進來，所以靜態清單沒有的 `*-free` 兩隻也會出現 |
| 存 key | `hermes auth add opencode-go --type api-key`；不存也行，設 `OPENCODE_GO_API_KEY` 即可 |

```
hermes --provider opencode-go -m space-bunny-free -z '...'        # PONG, rc=0
hermes --provider opencode-go -m longcat-2.5-preview-free -z '...' # PONG, rc=0
```

教訓：要幫工具補上游的協定細節之前，先 grep 那支工具的原始碼找 provider 名與標頭名 —— 修過的坑會留在註解裡。

## dcq — 併發跑者

`dc` 一次一張。`dcq` 是它的佇列前端：工單丟進去，N 個 slot 併發跑，成敗總表出來。

```bash
dcq add /abs/path/task.md [cwd] [easy|mid|hard]   # 入列（先過 deep-lint + wo-verify <task.md> --dry 准入閘；沒給難度由本機 Laya 判）
dcq start -j 4                    # 同 run，但進獨立 tmux（-L dcq）脫離呼叫端；agent session 派工用這個
dcq run -j 4                      # 前景跑到 pending 清空（預設 4，硬上限 8）
dcq status                        # 各狀態計數與失敗清單
dcq cancel <job-id>               # 取消一張（殺整棵程序樹、階梯不重試、移到 failed）
```

它不是 HTTP 客戶端。Go 的 `/zen/go/v1` 給的是推理不是 agent，要改檔案仍得跑 opencode 的 agentic loop —— 所以併發＝開 N 個 `dc` 進程。

四件事由 dcq 負責，其餘全部複用 `dc`：

| | |
|---|---|
| **slot 分配** | `pending/ → running/ → done\|failed/`，搶單靠 `mv` 的 atomic rename，不另加鎖 |
| **per-job cwd 互斥** | 唯一會讓併發出「錯誤結果」而非只是變慢的項目：opencode 對工作目錄做 snapshot、`wo-verify` 斷言又是相對路徑，兩張工單共用 cwd 會互相汙染。鎖本身與 `dc` 共用同一把（見上），dcq 這邊只負責「搶不到就換下一張，不阻塞 worker」 |
| **模型池** | 2026-10-19 起各層預設名單由 `catalog/models.tsv` 組成，見下方「清冊與難度分層」；以下為 2026-10-09 版的歷史紀錄。2026-10-09 起 `DCQ_POOL_ZEN`（手排 nemotron-3-ultra → space-bunny → step-5 → ling-3.1-flash → mimo）在前、`DCQ_POOL_GO`（預設 `longcat-2.5-preview-free`）殿後當兜底，實際順序每次啟動由 autorank 依 `gaps.tsv` 重算（`dcq rank` 印表）：longcat 19 跑 9 次 300s 停滯（471 s/pass，已 demoted），space-bunny 25 跑 21 PASS（85 s/pass），nemotron-3-ultra 16 跑 0 停滯（107 s/pass）。降級有兩道：停滯率 ≥`DCQ_RANK_STALL_PCT`（30%）；以及 2026-10-09 加的短路——樣本 ≥`DCQ_RANK_ZERO_N`（3）而 PASS 為 0 就不等 `DCQ_RANK_MIN` 直接降（nemotron-3.5-lightning 5 跑 0 PASS、1 停滯、曾自稱完成而驗收 FAIL）。降級只是移到免費層最後，仍排在付費層前，過一張就自己回昇。muse-spark／mimo／big-pickle／space-bunny-free／free-tools 2026-10-07 實測 420s 無產出已移出池。依序挑「本單沒試過、沒在冷卻、槽沒滿」的第一隻。`rc=1/124`（上游）換下一個；`rc=2`（工單契約錯）不重試。沒訂 Go 就 `DCQ_POOL_GO=`。`DCQ_MODELS` 有設就整條覆寫 |
| **per-model 冷卻** | 借鏡 LiteLLM Router 的 `allowed_fails`／`cooldown_time`：同一隻連續 `DCQ_ALLOWED_FAILS`（2）次上游失敗或停滯，冷卻 `DCQ_COOLDOWN_S`（120）秒，期間不派給它。只罰那一隻 —— 舊版是全隊熔斷，一隻掛全隊停 |
| **權重：免費優先** | 免費池整輪試過 `DCQ_FREE_ROUNDS`（2）輪都失敗，**或**免費模型全在冷卻，才 fallback 到 `DCQ_POOL_PAID`（預設 7 隻，依實測「寫得對＞反應快」排序：`opencode-go/glm-5.3-flash opencode-go/deepseek-v4.1-flash opencode-go/deepseek-v4-pro opencode-go/minimax-m3 opencode-go/qwen3.8-flash opencode-go/kimi-k2.7-code opencode-go/glm-5.3`。Go 額度 per-model 各自計，多放＝容量相加；與 Zen 免費同底模的 muse／mimo Go 版不收；deepseek-v4-flash 上游退役，2026-10-03 移除）。用過訂閱層的工單在 jobfile 標 `PAID=1`。`DCQ_POOL_PAID=` 設空＝永不動用，免費全冷卻時就等 |
| **per-model 併發槽** | 單一模型同時最多 `DCQ_MODEL_MAX`（3）張，滿了直接分給下一隻，不在忙的模型上排隊 |
| **watchdog** | opencode 的 `chunkTimeout` 有洞（[#43519](https://github.com/anomalyco/opencode/issues/43519) SSE keepalive 會歸零計時、[#48675](https://github.com/anomalyco/opencode/issues/48675) 一個 chunk 都沒送就卡住不報錯），外面再看一層：每 `DCQ_POLL_S`（5）秒看 `.out` 的 mtime，靜默 ≥ `DCQ_STALL_S`（200；2026-10-09 起，依 gaps.tsv 39 張 PASS 最大靜默 162s 留 25% 餘量）秒判停滯 → 殺整棵樹、冷卻計數＋1、換下一隻。單隻模型一次嘗試超過 `DCQ_ATTEMPT_MAX`（600，≈PASS 單次最長 294s×2）秒也一樣換手——一直有輸出的無限迴圈不會觸發停滯。整張工單超過 `DCQ_JOB_MAX`（2700）秒也殺，但**不罰模型、不換**（防 [#52092](https://github.com/anomalyco/opencode/issues/52092) 失控迴圈燒光 Go 額度）。2026-10-21 起，opencode 底下有工具子程序在跑（多半是模型自己跑的慢測試）時，停滯與防空轉都不計時；`dc` 也把 opencode bash 工具的預設逾時從 120s 拉到 300s（`OPENCODE_EXPERIMENTAL_BASH_DEFAULT_TIMEOUT_MS`，已設就不覆寫）。之前慢測試會先被 120s 砍掉，再被 watchdog 判 slow／spin 換模型 |
| **取消** | `dcq cancel <id>`：先寫 `.cancel/<id>` 標記再殺程序樹，順序不能反 —— 反過來 `run_job` 會把 kill 的 rc 當成模型失敗，直接換下一個模型重跑同一張，人工中止永遠停不下來。`dc` 是 bash 殼，殺它不會帶走 opencode，所以殺整棵樹 |

併發上限硬夾 8：社群實測 1–5 穩、10–32 崩，官方只說 "traffic is monitored for abuse" 沒給數字。衝高併發的期望值是被 ban，不是更快。

**2026-09-30 本機實測**（Go 訂閱後，`space-bunny-free`，每張工單自己的 cwd）：4 併發 4/4 PASS、8 併發 8/8 PASS，全部第一個模型就中、沒用到 fallback。`opencode.db` 的 WAL 在 8 個並行 `opencode run` 下 **0 次** `database is locked`／`SQLITE_BUSY`。

**停滯門檻為什麼是 300 秒**：opencode 的輸出（文字或 `--format json`）是 **part 級**不是 token 級，2026-10-02 實測從開始串流到第一個 step 完成之間 10 秒完全沒輸出；長推理的正常 step 本來就會靜默數分鐘。門檻太緊會誤殺正常工作。每次跑完都會把最大靜默間隔記到 `~/.dcq/logs/gaps.tsv`（時間、模型、最大間隔、rc、原因），累積一週再依實際分佈收緊。`dc` 收尾的 `wo-verify` 也算在內，驗收指令很慢的工單要把門檻放寬。

`dcq status` 會列出每隻模型的 `busy=n/max` 與冷卻剩餘秒數。

環境變數：`DCQ_HOME`（預設 `~/.dcq`）、`DCQ_JOBS`、`DCQ_POOL_GO`、`DCQ_POOL_ZEN`、`DCQ_POOL_PAID`、`DCQ_FREE_ROUNDS`、`DCQ_MODELS`、`DCQ_MODEL_MAX`、`DCQ_ALLOWED_FAILS`、`DCQ_COOLDOWN_S`、`DCQ_STALL_S`、`DCQ_JOB_MAX`、`DCQ_ATTEMPT_MAX`、`DCQ_POLL_S`。舊名 `DCQ_BREAK_N`／`DCQ_BREAK_S` 仍可用，對應到 `DCQ_ALLOWED_FAILS`／`DCQ_COOLDOWN_S`。

自檢（都用假的下游，不打上游）：`./test/dcq_test.sh`（佇列、模型池、權重 fallback、冷卻、併發槽、watchdog、防空轉、cancel）、`./test/dc_lock_test.sh`（cwd 鎖）、`./test/dc_model_test.sh`（模型閘：哪些准派、哪些要拒）

每支測試開頭 source `test/env.sh`：清掉呼叫端的 `DC_*`／`DCQ_*`／`JEV_*`／`OPENCODE_*`，`XDG_CONFIG_HOME` 指到空的 fixture。所以在 dcq 工單裡（worker 帶著 `DC_FREE_MODEL` 等變數）跑測試，結果跟在乾淨 shell 一樣，也不受本機 `opencode.json` 影響（issue #13）。

跑全套時每支的 rc 要先存進變數再印：`for f in test/*.sh; do bash "$f" >/dev/null 2>&1; rc=$?; echo "$f rc=$rc"; done`。寫成 `echo "$(basename $f) rc=$?"` 的話，`$?` 拿到的是 `basename` 的 0，全部會顯示通過（2026-10-21 踩過）。

### 同一個 repo 的多張工單要併發：一張一個 git worktree

cwd 互斥讓同 repo 的工單只能串行。要併發就每張開一個 worktree 當 cwd，各自 PASS 後由主 session 逐張 merge：

```bash
git -C <repo> worktree add -b wo/A1 <wt>/A1 HEAD
ln -s <repo>/.venv <wt>/A1/.venv     # 沒進版控但驗收要用的東西（venv、logs）用 symlink 帶過去
dcq add /abs/A1.md <wt>/A1 mid
```

工單裡的 cwd 要寫 worktree 路徑。改同一個檔的兩張會在 merge 時衝突，衝突由主 session 處理。2026-10-21 實測 4 張同 repo 併發 3 張第一輪 PASS。

### 防空轉（watchdog 內建，零 token）

dcq 的停滯判定只看 `.out` 有沒有輸出。模型一直講話卻不改檔（繞圈讀檔、反覆重試同一招）抓不到，要等 `DCQ_ATTEMPT_MAX` 才換手。cwd 是 git 工作樹時，watchdog 另外看工作樹指紋（HEAD＋`git diff HEAD`＋未追蹤檔內容）：同一次嘗試 `DCQ_SPIN_S` 秒（預設 420）完全沒變，就殺這次嘗試，記 `why=spin`，跟 stall 一樣罰冷卻、換下一隻，`dcq rank` 的停滯欄也算它。

- 非 git cwd 不看。
- `.out` 出現 `dc: 驗收 →` 之後不看，慢驗收不會被誤殺。
- 唯讀工單（只產報告到 cwd 外）在 git cwd 裡跑超過 420s 會被誤殺：入列時帶 `DCQ_SPIN_S=0 dcq add ...`，這張就不看（記成工單的 `SPIN=0`）。

### 清冊與難度分層（2026-10-19）

`catalog/models.tsv` 是本機確實可調用模型的唯一清冊，每列標 `free`（免費）／`sub`（付費訂閱）／`api`（付費 API）。dcq 依清冊組層，順序固定為免費 → 訂閱 → API：

- 免費層：`free` 且 `dc_id` 無斜線（Zen 免費，只能經 `opencode run`），加上 `opencode-go/*-free`（2026-10-22 起，`DCQ_GOFREE_MAIN=0` 關）與直連的 `kilo/*`、`google/*`、`nvidia/*`、`groq/*`、`openrouter/*`（2026-10-25 起）。
- 兜底層：只剩 `omniroute/*`，**本機已空**（2026-10-26：`omniroute/or-free`、`omniroute/nim-pool` 退役，免費編排改走 `freepool` ＋ `kilo/kilo-auto/free`，NIM 走直連）。`fit=easy-only` 的只派 easy 工單（`or-free` 23 跑 1 過）。
  - 直連模型要有 key（`NVIDIA_API_KEY`／`GROQ_API_KEY`／`GEMINI_API_KEY`／`OPENROUTER_API_KEY`，或 opencode `auth.json`，或 `opencode.json` 的 `options.apiKey`），`opencode.json` 的 `enabled_providers` 沒排除該 provider，且（google 以外）模型列在 `provider.<p>.models`，否則組池時剔除。`omniroute/*` 沒在 `opencode.json` 宣告也剔除。

**不裝 OmniRoute**：清冊的 `omniroute/*` 會自動剔出，其餘照常。設定步驟：

1. 申請免費 key（[NVIDIA build](https://build.nvidia.com)、[Groq](https://console.groq.com)、[Google AI Studio](https://aistudio.google.com)；Kilo 免 key）放進環境變數。
2. `dcq doctor --fix > /tmp/patch.txt`，取 `{` 開頭那段存成 `patch.json`，`jq -s '.[0] * .[1]' ~/.config/opencode/opencode.json patch.json` 併入（key 只寫 `{env:}` 引用）。
3. 再跑 `dcq doctor`，exit 0 就完成。

### freepool：免費名單自己查（2026-10-26）

「哪些模型現在免費」不靠寫死的名單，也不靠別家路由器的組合名（OmniRoute 的 `or-free`／`free-tools` 就是這種保證）。`bin/freepool` 直接讀有公開價格目錄的 provider（Kilo、OpenRouter，都免 key），用 `pricing.prompt == 0 && pricing.completion == 0` 現場判定，並要求 `supported_parameters` 含 `tools`（執行人要能呼叫工具）。借鏡 [FreeToken-Bots](https://github.com/limin112/min-skill/tree/main/skills/FreeToken-Bots)：免費是動態的，過期名單不得授權呼叫。

```sh
freepool scan                      # 讀上游目錄、寫快取 ~/.dcq/freepool.json、印與上次的差異（零 token，不實打模型）
freepool pool                      # 此刻零價＋支援 tools 的 dc_id
freepool verify kilo/kilo-auto/free   # 單一 dc_id：rc 0 零價、2 現價非零、3 查不到
freepool guard catalog/models.tsv  # 清冊 billing=free 的 kilo／openrouter 列是否還零價；rc=1 有漲價或 id 缺後綴
freepool propose catalog/models.tsv   # 對清冊提增刪建議（只印，不改檔）
```

三個 fail-closed 的點：

- **dc 派工前先驗**（`kilo/*`、`openrouter/*`）：目錄說現價非零就不派（rc=1，dcq 冷卻這隻換下一隻）；`DC_FREEPOOL=off` 強制跳過。
- **缺 `:free` 後綴不放行**：`kilo/poolside/laguna-s-2.1` 與 `…:free` 是兩隻不同的模型，前者收費。少打後綴會靜默走付費版，所以 dc 直接中止並印出零價的那個 id。
- **沒快取也連不上上游時不宣告任何模型免費**（`pool` rc=1、`verify` 回 unknown）。快取過期（`FREEPOOL_TTL_H`，預設 24h）又連不上，判定會標「僅供參考」。

`oc-probe daily`（每天 06:00）跑 `scan` ＋ `guard`：新上架／下架／漲價印在 launchd log，清冊有列已不是零價就推 TG（那是會扣錢的事）。沒裝 oc-probe 就自己排一條 `freepool scan`，否則名單會過期。

其他 provider（Zen、NIM、Groq、Google AI Studio）沒有價格端點，`freepool` 回 `unknown` 不表態，計費分級照 `dc` 的 `tier()` 規則。

**實打可用性只走 `freepool probe`，禁止自己併發打。** Kilo 免 key 免費額度全帳號共用，10-26 用 `oc-free-check -p kilo -j 4` 打 22 隻，額度當場燒光（全回 `Free usage limit reached`），之前也被判過濫用。`freepool probe kilo/<id>...` 交給本機 OmniRoute 的 `POST /api/models/test-all`：逐個送、429 連 3 次或 403 連 2 次自動停；一次最多 5 個、只收目錄現價零的 id。它用 OmniRoute 裡的匿名 kilo 連線（`Kilo anonymous (combo)`，與 Coco 的 `kilo-free` combo 共用；原本停用才會在 probe 後關回去）。`oc-free-check -p kilo` 已直接拒跑。OmniRoute 只當探測工具，派工路徑不經過它。

各家免費額度實測（2026-10-25）：Groq 免費方案 8000 TPM，一次 opencode 請求約 8000 token，只放 easy；NVIDIA NIM 約 40 RPM，併發上限 2；OpenRouter `:free` 會被帳號的 guardrail（provider／資料政策限制）擋成 404，要先在 openrouter.ai 設定放行；Kilo Gateway 會記錄 prompt，機敏工單別派；Kilo 免 key 的免費額度是**整個帳號共用**，一次把十幾隻模型全探測一遍就會把當期額度打光（2026-10-26 實測：`oc-free-check -p kilo` 22 隻跑完後，所有 `kilo/*` 都回 `Free usage limit reached`），要探測就分批。
- 訂閱層：`sub`（`opencode-go/*`）。
- Claude 層（2026-10-25）：`sub` 且 `dc_id` 為 `claude/*`（目前 `claude/claude-haiku-5-5`），只在 `DCQ_ORDER=sub`（派os）排最後、API 前；派o／派of 不派。dc 經 `bin/claude-exec` 叫 `claude -p`（claude.ai 訂閱額度，與主 session 共用，provider 上限 1）。不能加 `--bare`（只認 API key＝按量計費）；`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` 有設時 bypassPermissions 會被降級，所以工具用 `--allowedTools` 明列。`DCQ_POOL_CLAUDE=` 關掉。
- API 層：`api`，`DCQ_ALLOW_API=1` 才接，預設不用。

兜底層與訂閱層也做層內排序（2026-10-21），規則同免費層：依每 PASS 秒數升冪，停滯率過高或 0 PASS 的墊該層最後，樣本不足留原位。只在層內排，不跨層搬。`DCQ_MODELS` 有設或 `DCQ_AUTORANK=0` 就不排。

### 額度用完、免費池縮水（2026-10-25）

- **額度用完不算模型失敗**：`dc` 看到 `Free usage limit reached`（Zen）、`Go usage limit exceeded`、Google 的 `Quota exceeded`／`RESOURCE_EXHAUSTED` 就提早結束，dcq 記 `why=quota`，不進 `.fails`、不拉低排名（issue #8）。限流與上游不可用記 `why=upstream`，同樣不算樣本。
- **Zen 額度整池冷卻到 UTC 午夜**（台灣 08:00）：Zen 免費額度按**出口 IP** 計，不分模型，同一台機器（或同一出口的多台）共用一份。撞到一次就整個 Zen 池停到重置，`dcq plan` 首行會寫「Zen 免費池冷卻到 HH:MM」（#10）。多機共用冷卻沒做：同出口的另一台要自己撞一次才知道。
- **Google AI Studio**：每日額度（RPD）冷到太平洋時間午夜，每分鐘額度（RPM）只冷 120 秒（`DCQ_QUOTA_RPM_COOL_S`）。免費層 RPD 很小（個位數到幾十次），只適合放兜底；免費層的輸入可能被 Google 用於改進產品，機敏工單別派（#11）。
- **免費池剔出看得到**：`dcq plan` 首行印各 provider 數與剔出名單。清冊同步會帶進新 provider，各機 `opencode.json` 卻不會跟著改，所以清冊有、本機沒宣告的只要 1 隻（`DCQ_MISS_ALERT`），或主層只剩一家 provider，`dcq plan`／`dcq add` 就印 WARN 並推 TG；同一天名單沒變只推一則（#9）。`dcq doctor` 做同樣的健檢：被 `enabled_providers`／`disabled_providers` 刻意關掉的列為「略過」，其餘剔出算壞、exit 1。`dcq doctor --fix` 另印 `opencode.json` 補丁（key 用 `{env:}` 引用），用 `jq -s '.[0] * .[1]'` 併入。
- **OmniRoute 健康檢查**：組池時對 `baseURL/models` 打一次（2 秒、結果快取 `DCQ_OR_HC_S`=120 秒），連不到就這次不派 `omniroute/*`（#12）。OmniRoute 在遠端、本機是 userspace Tailscale（沒有 TUN 介面）時，curl 與 opencode 都要走 Tailscale 的 SOCKS5／HTTP proxy：在 dcq 的環境設 `ALL_PROXY`／`HTTPS_PROXY`，否則健康檢查判掛、模型也連不到。`DCQ_OR_HC=0` 關閉檢查。

Claude Code（`claude-code` 列，沒有 `dc_id`）、Codex 也在清冊裡（`sub`），dcq 不派；由主 session 的 Agent 工具或 `codex exec` 直接用。dcq 派的 Claude 只有上面 `claude/*` 那幾列。

難度在 `dcq add` 時定一次：呼叫端給的優先，沒給一律 mid（2026-10-24 起預設不問 Laya；`DCQ_TRIAGE=1` 才跑 `bin/triage`），同一張工單中途不換：

- `hard` 工單跳過清冊 `fit=easy` 的模型（有改錯、假扮工具、無限迴圈或隨機分配的前科）。
- **best-of-N**（2026-10-25）：`hard` 工單在免費主層的強模型全在冷卻時，同派 `DCQ_BON_N`（預設 3，<2 關閉）隻沒冷卻的 `fit=easy` 模型，各在 `$DCQ_HOME/.bon/<id>.<k>` 的 git worktree 跑，第一隻過驗收的改動套回 cwd 再驗一次才算 PASS，其餘殺掉（被殺的不記帳）。cwd 不是 git 根目錄或有未 commit 改動就跳過，照原階梯。併發照常吃 per-model／per-provider 槽。依據 Large Language Monkeys（arXiv 2407.21787）。
- `gaps.tsv` 第 7 欄記難度，autorank 依難度各排一份；舊紀錄沒有這欄，算進每個難度。`dcq rank hard` 看 hard 的排名。

併發有三層：全域 `DCQ_JOBS`、per-model `DCQ_MODEL_MAX`，以及 per-provider 上限 `catalog/providers.tsv`（zen 2、opencode-go 4、google 2、kilo 2、nvidia 2、groq 1、omniroute 6）。Zen 免費池共用同一個 IP 閘，同時開太多會被判 abusive traffic 整池 403。

### Zen 封鎖閘（`zen-gate`）

`dc` 或 `oc-free-check` 偵測到 Zen 判濫用（403 Detect Abuse Traffic）就 `zen-gate trip`，本機所有 Zen 免費消費端停打。官方不公布解封期限，所以封鎖時間照連續輪數倍增（借鏡 OmniRoute `circuitBreaker`，2026-10-21）：

- 連續 3 輪內封 `DC_ZEN_GATE_S`（預設 21600＝6h），之後每輪 ×2，上限 `DC_ZEN_GATE_MAX_S`（預設 172800＝48h）。連敗計數存在 `~/.dcq/.zen-gate.streak`。
- 半開：閘到期但還有連敗計數時，dcq 把 zen 的併發上限壓到 1，只放一個探測。
- 探測的請求被上游正常回應（rc=0、沒有濫用字樣）就 `zen-gate ok` 清掉計數。判準是請求成功，不是驗收通過。

層級順序每張工單入列時記下（`DCQ_ORDER`）：`default` 免費優先（派o）、`free` 只用免費（派of）、`sub` 訂閱優先（派os）。`dcq plan <task.md>...` 在派工前印出每張的難度和會走的層，不入列。

系統一模型（Laya、Jev）只回結構化判斷，不生成文字，另列在 `catalog/judges.tsv`，dcq 不派。

輪子裁決：LiteLLM／Portkey／plano 是第二個閘道，跟 OmniRoute 重疊；RouteLLM、NotDiamond 已停更或封存。所以只借設計：LiteLLM `complexity_router` 的難度分層、oh-my-opencode 的 `providerConcurrency`。Thompson sampling 延後到任一難度有 ≥5 隻各 ≥20 筆紀錄（2026-10-19 只有 118 筆、3 隻 ≥10 筆）。

## 已知坑

- 免費端點會突然掛：實測 `ling-3.0-flash-fin-free` 回 `Upstream unavailable`。dc 不做自動 fallback。
- 免費池的帳單是 wall-clock：單一函式小修 17–20 秒，兩個函式加約束約 4 分鐘。長任務不要用 dc。
- 適用範圍：讀 codebase／追依賴／單點小修。跨多檔重構、需要 `GH_TOKEN`、要寫 `~/.claude/**` → 用 deep。
- `504 Upstream idle timeout exceeded` 的根因是**單輪閒置**，不是總時長：殺手是 `uv pip install`／`npm ci` 這種幾分鐘不吐 token 的步驟。這類指令由呼叫端先跑完，別靠重試硬碰。
- **工單裡的「預期：…」不是斷言**，wo-verify 只跑 shell 區塊看 exit code。`echo x | ./foo.sh` 永遠 rc=0，模型輸出錯的東西照樣 PASS。要比對輸出就寫成 `[ "$(...)" = "..." ]`。（實測：8 張同樣的工單，一張產出 `hello-world-foo-` 多一個 dash，仍被判過。）
- shell script 裡 `$var` 後面直接接中文標點會被 bash 吃進變數名（`rc，` → `rc\xef...: unbound variable`），在背景 worker 裡會變成靜默猝死。變數後接非 ASCII 一律寫 `${var}`。
- **`jq` 缺了會報一句誤導的錯**：`dc` 不會說「找不到 jq」，而是死在 `bin/dc:136` 的 `OPENCODE_CONFIG_CONTENT 不是合法 JSON`。真因是 `bin/dc:135` 那行 `jq` 輸出為空，`_cc` 跟著變空。
- **驗收裡的常數要跟組合數自己算一遍，`wo-verify --dry` 抓不到這個矛盾**。`--dry` 只驗 shell 區塊能不能解析，不驗它跟任務描述對不對得上。實測：任務檔寫「864 筆」但組合算出來是 `6×3×6×2×2 = 432`，`deep-lint` 與 `--dry` 都放行，最後是執行人自己讀出矛盾、報 `DC_TASK_DEFECT` 拒派（rc=2，不重試）。派工前把驗收裡的數字算一遍，比事後 debug 便宜。
- **Windows 只能經 git-bash 跑 `dc`，且路徑要用 `/c/...` 形式**：`dc` 要求絕對路徑，但 `C:\Users\...` 傳進 bash 後 `\U`、`\t` 會被當 escape 吃掉。從 PowerShell 呼叫要包一層，`-i` 不能省（`bash -c` 不讀 `.bashrc`，上面的 PATH 注入不生效）：

  ```powershell
  & "C:\Program Files\Git\bin\bash.exe" -i -c "dc /c/path/to/task.md /c/path/to/repo"
  ```

## 週探測（選配 `oc-probe/`）

`oc-probe/` 偵測 opencode 模型清單變化，自動改 dr 的清冊，不碰 OmniRoute。安裝：先跑本 repo `./install.sh`，再跑 `oc-probe/install.sh`（macOS launchd）。不裝也能用 dc／dcq，只是名單要手動維護。

| 來源 | 頻率 | 改什麼 |
|---|---|---|
| Zen 免費層實打（`oc-free-check`，經 `opencode run`） | 每 7 天，zen-gate 閘外 | `probe.tsv`：排序、GONE 移出 |
| Go 上游 `/models`（`go-sync`，零 token） | 每 7 天 | `go-models.json`：訂閱層與 `opencode-go/*-free` 增刪 |
| @opencode 推文（`oc-probe x`） | 每 4 小時 | `x-pool.tsv`：改名／上下架 |

三者偵測到變化都會跑 `dcq sync-catalog`，把增刪寫回 `catalog/models.tsv`。每日 job 最後跑選配 hook（`~/.config/oc-probe/hook`，存在才跑），給本機自己的後續動作用。

`dcq rank` 讀 `~/.dcq/logs/probe.tsv`（TSV：時間 provider 模型 狀態 秒數 原因），只用最新一批、≤`DCQ_PROBE_MAX_H`=192 小時（8 天，配合週探測）：

- 探測非 OK → 移到免費層最後（明天回 OK 自動回來）
- 樣本不足（manual）的位置依探測秒數排
- 真實工單的「每 PASS 秒數」仍是主排序——探測量得到活著與快慢，量不到寫碼能力

### 懲罰層與冷宮（累犯排在免費層之後）

自動排名判成 `demoted`（停滯率 ≥30%）的免費模型進懲罰層 `POOL_PEN`；判成 `zero`（≥3 筆 0 PASS）的進冷宮 `POOL_ZERO`（2026-10-22 起）：
**免費 → 懲罰層 → 兜底層 → 冷宮 → 訂閱（opencode-go，付費，2026-10-13 起墊底）**。會過但常卡的還值得試；0 PASS 的排在兜底層前面，等於每張工單替它白等 200–600s。
最近一筆樣本超過 `DCQ_RANK_PAROLE_D`（預設 7）天就假釋回免費層重新給機會。`dcq rank` 列出目前的懲罰層與冷宮。

免費層第 2 輪（`DCQ_FREE_ROUNDS`）只重試上游失敗的模型；已經跑到驗收、或 stall／slow／spin 的，本單不再給第二次（2026-10-22：wo-r1 同一隻 minimax 連跑 245s＋1021s）。

排序分數＝貝氏平滑後的每 PASS 秒數：`(總秒數＋K×全池平均秒數)／(PASS 數＋K×全池通過率)`，`K=DCQ_RANK_PRIOR_K`（預設 2，0＝原始 s/pass）。樣本少的往全池平均拉，所以不必再靠手排位置保護，manual 與 ranked 一起排。借鏡 LiteLLM latency-based routing 與 Beta-Bernoulli 先驗（arXiv 1707.02038）；Thompson sampling 等樣本夠再上。
探測批次比某隻最近一次 PASS 還舊時，`probe` 欄標 `stale`，不當 down（10-19 整池 403 那批）。
