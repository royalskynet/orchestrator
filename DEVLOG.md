# DEVLOG

## 2026-11-09：WO-F4

- worktree 恢復預設改寫主 checkout 絕對路徑到 `.src/<id>/wt/<原檔名>`，`TASK0=` 保留原快照；移除舊開關及 `.wt` 工單副本。pending 取消清快照；孤兒測試保留被殺時快照並驗證工單內容，新增兩個突變。


## 2026-11-09：WO-F2，codex 語意驗收的五個缺口

- **舊單補快照失敗擋下來**：`dcq_ensure_snapshot` 失敗不再用可變原路徑跑，這張單直接落 failed（`LAST_RC=2`），log 寫原因，不派模型。
- **hard＋冷卻不逃出指定清單**：帶 `MODELS=` 的單不進 best-of-N（候選取自 runner 的 `MODELS_hard`，會逃出清單）。取舍＝直接不進，而不是從清單選候選：指定模型就是要單一，N 隻同清單沒意義。
- **快照清理**：done／failed 結案、`add` 發布失敗、`clear`、`wt_gc` 孤兒兜底，都收 `$Q/.src/<id>/`。
- **`.wt` 不重複快照**：`wt_setup` 不再另複製 `<id>.task.md`（快照路徑與 worktree 無關），改寫副本改存 `.src/<id>/wt/<原檔名>`；`TASK0=` 保留原快照。
- `test/dcq_worktree_test.sh` 假 dc 改從工單內容 `# <name>` 認單（檔名不再帶 `-a` 後綴），WO-F4 補回預設路徑改寫與原快照不變驗證。
- `test/dcq_models_job_test.sh` 假 dc 的失敗清單擴到 f／g／o*／cool，補 default／free 不換層與 hard 冷卻案例。

## 2026-11-09：入列即快照（B2）、#23 補完

- **B2**：11-09 00:06 `wo-dcq-pin-warn` rc=2 Parse error，根因是 job 檔只存原工單路徑，派工後原檔被改寫。`dcq add` 改成一律寫 `$DCQ_HOME/.src/<id>/<原檔名>`（tmp→非空→mv），`TASK=` 指快照、`ORIG_TASK=` 記原路徑；舊單重派時補快照。保留原檔名，靠檔名認單的下游不受影響。
- **#23 補完**：`ORDER=sub` 分支會把指定模型的池換成訂閱池；改成 ORDER 之後再鎖回清單、各層池全清，`PAID=1` 移到鎖定之後才寫。
- 新增 `test/dcq_snapshot_test.sh`、`test/dcq_test_safety_test.sh`、`test/wo_e_acceptance_test.sh`（六次並行 dcq_tier 逐 pid wait＋四個突變）。

## 2026-11-08：dcq runner 隔離（#22）、逐單指定模型（#23）、dcq_tier 偶發紅（fixindex 11844）

- **#22**：`test/env.sh` 統一 `DCQ_AUTOSTART=0 DCQ_TMUX=dcqtest$$`，測試 runner 不再佔正式 socket `-L dcq`；`dcq_sock()` 讓沒設 `DCQ_TMUX` 時只有正式佇列 `~/.dcq` 用 `dcq`，其他佇列走 `dcq-<cksum>`。`dcq doctor`／`--fix` 抓並收掉指向別處的 runner（混了正式 runner 只報不殺）。
- **11844**：根因是 `dcq add` 自動起的 runner 與測試自己的 `dcq run` 搶同一暫存佇列，派單順序不定；隨 #22 消失。
- **#23**：`dcq add` 帶 `DCQ_MODELS` 時照 `PREFER` 寫法寫 `MODELS=` 進 job 檔，runner 遇到只跑那份清單、不套各層／`PREFER`／不升級；runner 自己的 `DCQ_MODELS` 照舊。
- 新增 `test/dcq_isolation_test.sh`、`test/dcq_models_job_test.sh`（假 tmux／假 dc）。

## 2026-11-08：Codex 執行人

- 新增 `bin/codex-exec`，將 Codex JSONL 轉為 dc 開工、文字、指令與錯誤行；default 沿用設定模型，規則前置 prompt，使用 CLI 自帶 sandbox。
- dc 支援 `codex/*` 分流、訂閱分級及 `DC_MODEL`，沿用 gate；dcq 以 `DCQ_MODELS` 明確指定，不新增層。
- `test/dc_codex_test.sh` 用假 Codex 驗參數、錯誤 rc、額度字串及真實 gate 驗收產物。

## 2026-11-08：抽共用 gate 判定鏈與作弊掃描

- `bin/gate preflight` 統一 lint、負向對照、pin、regress 基準與範圍快照；`judge` 統一範圍、工單瑕疵、K 次驗收及回歸判定，供 dc／deep 共用。dc 保留執行、計費、鎖與上游分類。
- judge 新增作弊掃描：本次新增 skip 或刪追蹤測試回 `exit 6`；排除跑前髒檔，`ALLOW-SKIP: <理由>` 可略過。dcq 既有 `*)` 分支會換下一隻、不罰模型，無須修改。
- 新增 `test/gate_test.sh`，直接驗 preflight／judge 與作弊防線，並以移除 `exit 6` 的突變確認測試會失敗。

## 2026-11-08：regress:／writes!: 判失敗（#21）；Google 同額度桶一併冷卻（#11）

- **#21**：`dc` 加 `regress: <指令>`——派工前拍基準、驗收後比對，基準綠→完工紅或消失＝`exit 4`；`writes!:` 越界 `exit 5`。`writes:` 舊行為不變（只標記）。dcq 對 4／5 走 `*)`：換下一隻、不罰模型。輪子：對照乾淨基準只算新增失敗（Chromium CQ「retry without patch」同概念），stdlib awk 自寫。
- **#11**：本機 log 6 筆請求 3.5 回 3.6 標籤、2 筆 3.7→3.8、11 筆 3-flash-preview→3-flash，確認共用額度桶。`cool_quota` 抽 `Quota exceeded for metric` 行的 `model:`，`quota_alias_cool` 從觀測學對應並一起冷卻，不寫死名單。
- 派 deep 執行：deep 的測試夾具把 `$T` 寫成字面量（regress 指令讀不到檔），且改了 `watch_oc` 回傳格式；主 session 修夾具、還原 `watch_oc`／`bon_run`。

## 2026-11-02：dcq 三點借鑒（DeepSeek Harness〈Super-agent Design〉）wheel 裁決

- **派工回報限字數**：不做——`dcq wait` 只回 `PASS`／`FAIL rc=N`（上一節已實測）。
- **輪子：借鏡 自造｜借鏡（`systemctl status`／MCP `resource_link` 只取格式，零依賴）**
- **A `dcq status <id>` 摘要**：格式照 `systemctl status`——結果行（rc／cancelled／merge）＋ `.out` 去重限行錯誤；社群兩單（burpctl#15、cezar-factory#103）同結論「一線結論＋限行原文」。無現成 CLI 可裝。
- **B pass-through（`add --src`）**：Aider `--restore-chat-history`、Codex `exec resume`、Claude Code `--resume` 都靠「同一份 session 檔還在」；dcq 換模型重試時前張單可能被別家模型跑，session 不互通。只借「a 張單入列帶前張 cwd 分支＋摘要」的設計。
- **C `fixindex find --spill`**：對齊 MCP `resource_link`（只回 URI＋摘要，`resources/read` 才取全文）；RAG 叫 progressive disclosure，社群無權威討論（HN 訊號<2），自寫。
- **警示**：B 會改工作目錄狀態（worktree 分支 merge），先用假 dc 測試釘住。計畫 `~/.claude/plans/dcq-superagent-borrow.md`。

## 2026-11-02：重驗「派工回報只回結論」假設（未改碼）

- **假設**（由 DeepSeek Harness〈Super-agent Design〉借鑒推導）：主 session 吃 `dcq wait` 的結果會把整份 `.out` 帶回來，要改成只輸結論。
- **實測**：`dcq wait` 只印 `PASS <id>`（done 成立）／`FAIL <id> rc=N`（讀 `LAST_RC=`），`run_job` 的過程訊息全走 stderr，不進主 session。**假設不成立**，不需要限字數。
- **真缺口**：單張工單的失敗原因與 merge 狀態分散在 `~/.dcq/failed/<id>.job`（`LAST_RC=`、`CANCELLED=`、`MERGE=`）與 `logs/<id>.*.out`，沒有彙總指令。
- 待辦（計畫 `~/.claude/plans/dcq-superagent-borrow.md`）：A `dcq status <id>` 摘要、B `add --src` pass-through、C fixindex `find --spill`。

## 2026-10-22：改名 Orchestrator，觸發詞派o／派of／派os

- **定位**：模型來源早已不限 opencode（Zen 免費、opencode-go 訂閱、OmniRoute 轉接的 NIM／OpenRouter、付費 API 都在 `catalog/models.tsv`），opencode CLI 只當 agent 外殼。README 中英說明改寫成「多 LLM 依實績智慧調配」。
- **改名**：公開 repo `royalskynet/dispatch-router` → `royalskynet/orchestrator`（GitHub 舊網址自動轉址）。本機路徑 `~/dev/dispatch-router` 與 ether-projects 子目錄不動，避免 launchd、symlink、subtree 歷史斷掉。
- **觸發詞**：派dr→派o、派drf→派of、派drs→派os；skill `dr`→`o`（`~/.claude/skills/o`）。路由 regex 只認單字 o／of／os，不吃 opus、openai；舊稱派dr 保留為別名。底層 `dc`／`dcq` 不變。

## 2026-10-22：免費層智慧加權、冷宮、FreeTierError 閘

- **起因**：10-21 晚 wo-r1／r8／r9 免費層各卡 20–40 分鐘撞 `JOB_MAX` 2700s。卡在單一模型跑太久＋排序，不是併發（gaps.tsv 221 筆：同模型同時 0 張過關率 12%，1–2 張 41–54%）。
- **智慧加權**（257419e）：`rank_free` 的每 PASS 秒數加貝氏先驗，`est=(總秒數+K·全池平均秒數)/(PASS+K·全池通過率)`，`DCQ_RANK_PRIOR_K=2`。小樣本往全池平均拉，manual 與 ranked 合排。借鏡 LiteLLM latency-based routing 與 Beta-Bernoulli 先驗；Thompson sampling 等樣本夠再上。
- **冷宮**：0 PASS（zero）移出懲罰層，排兜底層之後、訂閱層之前。以前 8 隻懲罰層有 5 隻 0 PASS，每隻白等 200–600s，擋住兜底層最好的 `opencode-go/beam-free`。
- **Go 免費併入主免費層**：`opencode-go/*-free` 走 Go key，跟 Zen 的 per-IP 閘分開，免費併發 zen=2＋opencode-go=4。`DCQ_GOFREE_MAIN=0` 關。mid 工單第一棒變 `go/beam-free`（7/7）。
- **第 2 輪只重試上游失敗的**：dc 驗收未過也回 rc=1，跟上游失敗同碼；改看 `.out` 有沒有 `dc: 驗收 →`。實例：wo-r1 同一隻 minimax 連跑 245s＋1021s。
- **`fit=easy-only`**：mid／hard 都不派。`omniroute/or-free` 23 跑 1 過、失敗白等 11262s。
- **探測過時**：探測批次早於某隻最近一次 PASS 標 `stale`，不當 down（10-19 06:00 整池 403 那批）。清冊 status 依 gaps.tsv 重設。
- **FreeTierError 閘**（090ad3e）：`ABUSE_RE` 補 "free tier can only be used from within OpenCode"。10-18 整個 IP 中這句，dc 只認 abusive 措辭，19 時一小時照送 74 次全 403。
- **官方規則核對**：Zen 免費只能經 opencode 客戶端；deny read／bash、自訂 zen baseURL、舊式 `tools:{bash:false}` 會被判非正版（anomalyco/opencode#56324、#56702）。dc 設定合規。速率與濫用判定按 IP（#43786），官方無併發上限，`zen=2` 維持。
- **Jev 與 Zen 403 無關**：本機第一筆 403 10-18 10:15（opencode 客戶端），Jev 12:41 才中；封鎖前 Jev 每小時 1 次；上游 #56324 10-17 開單 69 留言。細節 fixindex 11236、11240。
- **測試**：`dcq_rank_test` 12)、`dcq_test` 11e／11f、`dcq_tier_test` 4b、`dc_upstream_test` FreeTierError；11e 與 FreeTierError 改前都 FAIL。全套 15 支 0 失敗。

## 2026-10-21：慢測試不誤殺、Zen 閘退避、重試只驗一次、推播閘

- **慢測試誤殺**（80184d1）：opencode bash 工具內建 120s 逾時，模型自己跑的慢測試先被砍，再被 watchdog 判 slow／spin 換模型。`dc` 設 `OPENCODE_EXPERIMENTAL_BASH_DEFAULT_TIMEOUT_MS=300000`；dcq 的 `oc_busy` 看到 opencode 底下有工具子程序就不計停滯與防空轉。
- **WO-1 zen-gate 延遲倍增＋半開**（df303ed）：連續 3 輪後封鎖時間每輪 ×2，上限 48h；到期只放一個探測，上游正常回應才清計數。借鏡 OmniRoute `circuitBreaker`。
- **WO-3 前置檢查憑證**（3eddc84）：第一次 lint 與負向對照都過就存下 pin，重試沿用，不重跑也不重抽評分器。
- **WO-2 層內排序**（4427735）：兜底層與訂閱層照免費層的 `rank_free` 排。
- **推播閘**（d9bb54f、e2c6e7b）：狀態路徑不是正式路徑就不送 TG，`DC_PUSH=1` 強制推。起因是工單模型把 `DC_ZEN_GATE` 指到暫存後手動 trip 5 次，發出 5 則誤報。涵蓋 zen-gate、dc 帳單、freecheck、oc-free-check、go-sync；go-sync 補了第一支推播測試。
- **踩坑**：測試迴圈寫成 `echo "$(basename $f) rc=$?"`，`$?` 取到 `basename` 的 0，一度把全套誤報成全過。rc 要先存變數。

## 2026-10-19：清冊驅動＋難度分層＋provider 併發

- `catalog/models.tsv`：本機模型清冊（free／sub／api），加 `dc_id`、`fit` 欄；dcq 各層預設名單改由清冊組，不再寫死。
- Agnes 2.0 Flash 7 天 0/801 成功，移出兜底層。
- `bin/triage`：入列時用本機 Laya 判 easy／mid／hard；hard 不派 `fit=easy`；`gaps.tsv` 加第 7 欄難度，autorank 依難度分開排。
- `catalog/providers.tsv`：per-provider 併發槽（zen 2，防 Zen IP 閘判濫用）。
- API 層接在訂閱層後，`DCQ_ALLOW_API=1` 才開。
- 測試：`test/dcq_tier_test.sh` 23 項；弄壞 fit 過濾與 provider 槽各一次，測試都會 fail。

## 2026-10-01 ～ 10-03：oc-agent → dispatch-router

### 做了什麼
- **issue #1 cwd 鎖**：dc 自己拿鎖，dc 與 dcq 共用 `~/.dcq/.cwdlock/<hash>`；撞鎖 exit 75，持有者已死的孤兒鎖自動清除（f746f65）。
- **issue #2 乾等／無法取消**：新增 `dcq cancel <id>`，被 kill 不算模型失敗（b0ddf4f）。
- **模型池＋個別冷卻＋watchdog**（4aac2d5）：Go 免費 → Zen 免費 → 付費。每個模型連敗 2 次冷卻 120s、同時最多 3 張；`.out` 超過 300s 沒動靜就殺整棵程序樹並冷卻該模型；總時限 2700s。每張的最大靜默時間記 `logs/gaps.tsv`。
- **免費優先**（19c3212）：免費模型跑滿 2 輪都失敗，或全在冷卻，才動用付費層，jobfile 標 `PAID=1`。
- **改名**（af14532）：oc／ocq → dc／dcq，repo 改名 dispatch-router。它已不限於 opencode，OmniRoute 也是上游之一。
- **計費分級只警示不擋**（af14532、0a67347）：`tier()` 分 free／sub／metered，跟 provider 無關。非免費一律先記 `logs/billing.tsv`，再發 TG；TG 10 分鐘最多一則，下一則附被壓掉的筆數（`DC_TG_EVERY`，d124dbd）。
- **模型擴充**：Zen 加入 mimo、nemotron-3-ultra、muse-spark-1.3-contributor-free 與 omniroute/free-tools 兜底；付費層從 2 個擴到 8 個 Go 模型（d4591c1、83d1ede）。
- **排序**：依 2026-10-03 同一張修 bug 工單的實測，寫得對優先、反應快其次（d124dbd）。

### 踩坑（細節在 fixindex）
- **opencode 免費層只認 CLI 身分**：經 API 呼叫或 OmniRoute 代打一律 403，偽裝 User-Agent 也沒用。所以 big-pickle 只能由 dc 直接派，已移出 OmniRoute 的 free-tools（9753）。
- **big-pickle 偶發用文字假扮工具呼叫**：輸出看起來有寫檔、跑驗收，磁碟上其實沒有任何檔案。用 `-- --format json` 看 `tool_use` 事件數就能分辨（9775）。
- **模型名稱帶 -free 不等於免費**：限時免費到期後名字不變，計費會變，要以額度和計費端點為準（9773）。
- **Go 額度是每個模型各自計算**：付費層多放幾個模型＝容量相加（9773）。
- **agent 工作的成本主要在 cache read 和 input**：output 單價影響很小。每張工單成本可以從 `--format json` 的 step_finish 加總，deepseek flash 約 $0.004，kimi-k3／grok 約 $0.12（9773）。
- **bash 3.2 下變數名緊接全形字元**：`$X（` 會在 set -u 下崩潰，一律寫成 `${X}`，已加 lint（9750）。

### 實測（2026-10-03，修 bug 工單，每個模型 1 個樣本）
| 組 | 模型 | 秒數 | 備註 |
|---|---|---|---|
| Go 免費 | space-bunny／longcat-2.5-preview | 8／9 | |
| Zen 免費 | nemotron-3-ultra／muse-spark／mimo-flash | 12／17／28 | |
| Zen 免費 | big-pickle | ~30 | 4 次裡卡住 1 次、假扮工具呼叫 1 次 |
| Zen 免費 | nemotron-3.5-lightning | 94 | 改錯 |
| Zen 免費 | fledge-alpha／ling-3.x | — | 連最小請求都失敗，不收 |
| 付費 | glm-5.3-flash／deepseek-v4-flash／v4.1-flash／v4-pro／minimax-m3／qwen3.8-flash | 12–28 | 已收 |
| 付費 | kimi-k3／qwen3.8-max／grok-4.7 | 22–27 | 每月額度不到 1k 次，不收 |
| 付費 | gpt-6-luna／hy4-preview | 114／222 | 太慢，不收 |

### 待辦／已結案
- （條件觸發，現在不做）依真實工單的通過率與耗時自動排序：等真實工單顯示目前排序明顯不對時再做。
- （已結案）freecheck 回報 Go 每週額度 5%：來源是 Hermes 的 Coco，它自 10-01 起預設 `opencode-go/deepseek-v4.1-flash`（訂閱模型）。Go 額度按模型各自計，Coco 和 dcq 付費層的 deepseek-v4.1-flash 共用同一份月額度（13 萬次），量級不衝突。
- （已結案，不是問題）`dc` 蓋過 `/usr/bin/dc` 計算機：本機腳本（openclaw／claude scripts、hooks、~/.local/bin、~/dev/*/bin）沒有人把 dc 當計算機用（`| dc`、`dc -e` 皆 0 筆）。注意 33 個 LaunchAgent 的 PATH 含 `~/.local/bin`，日後若有腳本要用計算機請寫 `/usr/bin/dc`。就算誤呼叫，dc 也會報錯退出，不會靜默算錯。

派os 的 CLI 訂閱層：codex → claude。
