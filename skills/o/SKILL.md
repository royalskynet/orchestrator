---
name: o
description: Orchestrator：把工單派給本機已知的各種 LLM（Zen 免費、opencode-go 訂閱、直連免費的 Kilo／NIM／Groq／Google AI Studio、付費 API）當執行人，依實測通過率與耗時智慧加權排序、多層 fallback；opencode CLI 當 agent 外殼，完工由 wo-verify 機械判定，exit code 反映驗收結果而非模型自述；多張工單用 dcq 併發跑（cwd 互斥、per-model 冷卻、停滯 watchdog），非免費模型發 TG 警示。說「派o」「派 o」「派工」時用；「派of」＝只用免費層、「派os」＝訂閱優先（底層指令是 dc／dcq；舊稱派dr／派drf／派drs 同義）；說「派deep」走 deepclaude 的 deep skill，不是這裡。需要沙箱外寫入、GH_TOKEN 或獨立 config 的由主 session 直接做，需 agent 多步自主時改派deep。
---

# Orchestrator（dc／dcq）＝多 LLM 執行人調度（免費優先、訂閱墊底），完成定義＝wo-verify 通過

**預設派工執行人**（觸發詞「派o」）。deepclaude 的「派deep」是另一條線，只補 dc 做不到、又需要 agent 多步自主的場景。dc 走 opencode 客戶端路徑，**免認證即可用**，且沒有 Anthropic 協定牆（整個 Zen 免費池都能用）。

## dc 做不到的部分

| 情境 | 誰做 |
|---|---|
| 讀 codebase／追依賴／單點小修／想快速試一個想法 | **dc** |
| 要寫 `~/.claude/**`、`.git/config`、launchd | 主 session 直接做；需 agent 多步自主時改派deep |
| 需要 `GH_TOKEN`（`gh search`／push／PR 等） | 主 session 直接做；需 agent 多步自主時改派deep |

派deep 的任務檔契約見 `~/.claude/skills/deep/SKILL.md`（2026-10-16 起取消「後備理由」閘門）。

## 任務檔

**契約沿用舊 deep skill 的工單格式，全文在 `~/.claude/skills-disabled/deep/SKILL.md`，不在此重抄**（deep-lint／驗收 shell 區塊／「預期：」行／`## 禁止` 段／≤40 行）。

dc 在派工前跑同一套閘門：`deep-lint` 不過就不派，`wo-verify <task.md> --dry`（旗標在檔名之後） 語法錯就不派。

## 派工設計六條（免費池能不能用，取決於工單怎麼寫）

免費池的限制不是額度，是**逾時、無 caching、可用性波動**。這六條是繞過三者的寫法，缺一條長任務就會斷在半路。

1. **單輪不得有長時間無輸出的指令。** `504 Upstream idle timeout exceeded` 是**閒置**逾時，不是總時長上限——殺手是 `uv pip install`／`npm ci`／大型下載這種幾分鐘不吐 token 的步驟。這類指令由呼叫端先跑完，dc 只接需要判斷的部分。
2. **一工單一目標。** 多步工單斷在第 N 步，前面全部白跑。拆成數張單步工單，每張自帶 `## 驗收`，用 `wo-verify` 的 rc 決定要不要重派；斷了只重跑那一張。
3. **模型釘死，不用 auto 路由。** OmniRoute 的 `auto/best-free` 每次挑到不同 `dc/*`，而 `dc/*` 對外部 API 一律 `FreeTierError` 403 —— 必掛。走 `DC_FREE_MODEL` 指定單一模型。
4. **驗收要寫成真斷言，而且未動工前必須失敗。**「預期：…」那行 wo-verify **不檢查**，只跑 shell 區塊看 exit code —— `echo x | ./foo.sh` 永遠 rc=0，模型做錯照樣 PASS。比對輸出寫 `[ "$(...)" = "..." ]`。dc 派工前會先在同一個 cwd 跑一次驗收當 **do-nothing 負向對照**：此刻就通過＝驗收是空包彈或工單是 no-op，當場 `exit 2` 不派工。確認既有狀態型的工單加一行 `NEG-CONTROL: n/a`。
5. **工單寫成冪等。** 斷言寫「已存在就跳過」而非「建立」。重派不會破壞前一輪成果，這是能無腦重試的前提。
6. **context 放檔案，不放 prompt。** Zen 免費池沒有 prompt caching，每輪重送 context 都是全價重算（Go lane 有，回應帶 `cached_tokens`；但工單大小本來就該由檔案承載）。工單給絕對路徑讓模型自己讀，禁止把檔案內容貼進任務檔。

判斷式：**主 session 預估 5 分鐘內做得完就自己做，超過才派 of**（2026-10-20 定，dcq 入列到結束 p50≈8 分鐘，fixindex 11066）。超過門檻不必等使用者說派工，主 session 主動提出，照下方「三種派法」直接派（`dcq plan` 輸出附在回報、不等答覆），走 `o-worker` subagent。上面三條（單步、冪等、輸入給路徑）是**寫工單的要求，不是派不派的門檻**：不滿足就拆成多張單步 dcq 工單，不是退回主 session。只有需要判斷力（設計取捨、找根因）或碰禁區（見上表）才主 session 自己做。

**單張也走 dcq**：只有 dcq 有模型 fallback 鏈（免費層 autorank（含 opencode-go/*-free）→ 懲罰層 → 兜底層 → 冷宮（0 PASS）→ 訂閱層（付費，墊底））與逾時換手。裸 `dc` 只跑一隻模型，掛了就沒救（fix 10299），只在指定模型做實驗時用。

## 派工

```bash
dc <task.md> [cwd] [-- <opencode run 原生旗標>...]
```

- 任務檔路徑必須**絕對**。
- 模型**計費分級不擋**：free／sub（訂閱額度）／metered（按量或沒查過的組合），非 free 照派，每筆記 `billing.tsv`，TG 10 分鐘最多一則（`DC_TG_EVERY`）。別家組合名帶 `-free` 不算 free。`kilo/*`、`openrouter/*` 由 `bin/freepool` 讀上游價格目錄現場判定：現價非零或 id 缺 `:free` 後綴（會打到同名付費版）就 rc=1 不派，dcq 冷卻換下一隻；`DC_FREEPOOL=off` 跳過。
- 未指定模型時釘死 `space-bunny-free`，不吃 opencode config 的 per-agent 付費 model。
- **停止免費就終止並跳警報**：派工前 `bin/freecheck` 查 `/zen/go/v1/usage`，任一額度窗 `status != ok`，或要用的 Go 免費模型從 `/models` 消失 → 寫 `~/.dcq/.ALARM`＋`hpush` 推播，`dc` rc=2 中止、`dcq` 全隊停止收單。名字有 `-free` 不代表還免費（Go 的免費是限時的），額度才是事實（`percent > 0` 只 WARN 不停：付費層和別處用 Go 都會讓它上升）。誤報就 `DC_FREECHECK=off`，或刪掉 `.ALARM`。
- `--agent <name>` 可指定 opencode agent（控制工具權限），但模型仍由 dc 釘死。
- **同一個 cwd 一次只准一個 dc**：`dc` 自己拿 `~/.dcq/.cwdlock/<hash>` 的原子鎖（與 `dcq` 同一把），撞上就 `exit 75` 並印持鎖者 pid，不會兩個 agent 寫同一目錄互相覆蓋。要排隊就 `DC_LOCK_WAIT=<秒>`。看到 rc=75 不是上游壞了，是有人在那個目錄跑，換目錄或等。
- **評分器釘住，改驗收＝判篡改**：派工前 `wo-verify --dump` 把驗收腳本抽出存一份 pin，派工後用 `--pinned` 跑那一份並逐行比對工單當下的版本；不一致（含整段被刪）`exit 3`，絕不跑被改過的版本。看到 rc=3 不是工單瑕疵也不是上游壞了，是執行人動了評分器（fixindex 0372 §4／0373 的前例），要看 diff 查他到底有沒有做事。
- **驗收重跑 K 次全過才算 PASS**：`DC_VERIFY_K` 預設 2。單次通過只代表「至少成功過一次」；第 2 次才失敗會印「驗收或改動不穩定（flaky）」，不要只憑第一次通過結案。驗收很慢時再降成 1。
- **chunkTimeout WARN**：provider 沒設 `chunkTimeout` 時上游停滯會乾等（5 分鐘預設 v1.18.27 才有，更舊可能無上限，外觀等同卡死）。`dc` 只出聲不擋，看到 WARN 就去 `opencode.json` 設 `provider.<p>.options.chunkTimeout: 120000`。
- 環境變數：`DC_FREE_EXTRA`（補免費白名單）、`DC_FREE_MODEL`（換預設免費模型）、`DC_FREECHECK=off`（關計費閘）、`DC_SKIP_LINT=1`（跳過 lint）、`DC_BIN`（覆寫 wo-verify／deep-lint 所在目錄，預設 repo `bin/`，測試注入假閘用）、`DC_LOCK_WAIT`（撞鎖時等幾秒，預設 0＝不等）、`DC_NO_TIMEOUT_WARN=1`（關 chunkTimeout WARN）、`DC_NEGCTL=0`（關 do-nothing 負向對照）、`DC_NEGCTL_TIMEOUT`（負向對照逾時，預設 120s）、`DC_VERIFY_K`（驗收重跑次數，預設 2）。

## 三種派法（2026-10-20 使用者定）

| 觸發詞 | 層級順序 | `DCQ_ORDER` |
|---|---|---|
| 派o／派工 | 免費 → 懲罰 → 兜底 → 訂閱 → API（API 預設關） | `default` |
| 派of | 只用免費的層；免費全敗就結案失敗，不升級 | `free` |
| 派os | 訂閱先，用盡才回免費的層，API 墊底 | `sub` |

流程固定三步：
1. 寫好工單後跑 `DCQ_ORDER=<順序> ~/dev/dispatch-router/bin/dcq plan <task.md>...`。它會用本機 Laya 判每張的難度（easy／mid／hard，零 token），印出會走的層和併發上限，不入列。hard 工單會跳過清冊 `fit=easy` 的模型。
2. 把 plan 的輸出原樣附在回報裡，**不問、不等答覆**（2026-10-22 使用者定，取消 10-20 的「問一次」例外）。只有一種情況要問：要開 API 層（`DCQ_ALLOW_API=1`，按量扣錢）。訂閱層是已付定額，不算花錢。
3. 緊接著每張跑 `DCQ_ORDER=<順序> dcq add <task.md> <cwd> <plan 判的難度>`，再跑 `dcq start -j N`。難度照 plan 給的值帶進去，入列時不再判第二次。

模型池來源是 `catalog/models.tsv`（free／sub／api 標籤），per-provider 併發上限在 `catalog/providers.tsv`。系統一模型（Laya、Jev）在 `catalog/judges.tsv`，只做判斷題，不能派工。

## Zen 與 Go 分清楚（2026-10-20 使用者定，fixindex 11041）

派o 的順序照上表：免費 → 訂閱 → 付費（API）。這節只管呼叫方式，判準是**端點／前綴，不是模型名**。

| 前綴 | 端點 | 能不能走 API |
|---|---|---|
| `opencode/…`（dc_id 無前綴，Zen） | `opencode.ai/zen/v1` | 不能。只准 `opencode run`／`dc`／`dcq` |
| `opencode-go/…`（Go，含 Go 上的 `*-free`） | `opencode.ai/zen/go/v1` | 可以，但 dcq 只走 opencode run（10-20 起 OmniRoute 不含 OC，go-free／go-sub combo 已刪） |

- 模型名會撞：`minimax-m3.1-flash-free`、`beam-free`、`longcat-2.5-preview-free` 在 Zen 和 Go 都有。看到裸名先判是哪個端點，不要憑名字推。
- Zen 的 API 沒回應不代表壞，不准判失效、不准重試探測：會被判濫用、封整個 IP 的 Zen 池（10-19 整池 403）。要知道能不能用，看 06:00 probe 排名。
- 工單的 `ORDER` 入列時寫進 job 檔；重啟 runner 改不到排隊中的單，正在跑的單也不會中途換鏈。要改派法就改 job 檔或重新 `dcq add`。

## 多張工單就用 dcq（併發跑者）

一次派多張時不要自己開 N 個 `dc`：opencode 會對工作目錄做 snapshot、`wo-verify` 斷言又是相對路徑，兩張工單共用 cwd 會互相汙染（A 的產物讓 B 假過、B 的改動讓 A 假失敗）。`dcq` 把 cwd 互斥處理掉。

```bash
dcq add /abs/task1.md /path/to/repo-a
dcq add /abs/task2.md /path/to/repo-b
dcq start -j 4        # 從 agent session 派工用這個：runner 進獨立 tmux，session 收工不會連帶殺掉
dcq run -j 4          # 前景跑（預設 4，硬上限 8）；掛在呼叫端底下，呼叫端死就跟著死
dcq status            # 成敗總表
dcq wait <id>...      # 睡到這些工單結案；agent 一律用 run_in_background 跑，結束時 harness 自動叫回（零 token）
dcq cancel <job-id>   # 中止一張：殺整棵程序樹，階梯不重試，移到 failed 標 cancelled
```

**派完就掛 `dcq wait`**：`dcq add` 印出的 job id 全部收起來，`dcq start` 後立刻用 Bash `run_in_background` 跑 `dcq wait <ids>`。不掛 wait，agent 拿不到完成訊號，只能等人問才去看（2026-10-05 實例）。禁止改用 ScheduleWakeup／Monitor／sleep 輪詢。

要停一張工單用 `dcq cancel`，不要自己 `kill` —— 直接 kill 會被當成模型失敗，自動換下一個模型重跑同一張。

實測（2026-09-30，Go 訂閱後、`space-bunny-free`）：4 併發 4/4 PASS、8 併發 8/8 PASS，`opencode.db` WAL 零鎖衝突。CLI **沒有** `opencode-go/` provider，Go 模型直接掛 `opencode/` 底下。

Go 的 HTTP lane（`/zen/go/v1`）**對外是通的**，跟被 `FreeTierError` 擋死的免費 Zen lane 不是同一道閘；只帶 Bearer 會回 400 `MissingSessionID`，還要 `x-opencode-session` 與自訂 User-Agent，模型用裸 id。細節見 README。但 HTTP 給的是推理不是 agent，改檔案仍得走 CLI。

模型池：`DCQ_POOL_ZEN`（nemotron-3-ultra → space-bunny → step-5 → ling-3.1-flash → mimo）在前，`DCQ_POOL_GO`（longcat，40% 停滯）殿後兜底。每次啟動由 autorank 依 `gaps.tsv` 重算真實順序（`dcq rank` 看表），手排只是樣本不足時的後備。autorank 有兩道降級：停滯率 ≥30%（longcat），以及 ≥3 筆樣本而 0 PASS 的短路（nemotron-3.5-lightning，曾謊報驗收）。兩者都只降到免費層最後，過一張就自己回昇；`DCQ_MODELS` 有設就整條覆寫。`rc=1/124` 上游掛就換下一隻，`rc=2` 是工單契約錯不重試。

- **per-model 冷卻**：同一隻連續 `DCQ_ALLOWED_FAILS`（2）次上游失敗或停滯 → 冷卻 `DCQ_COOLDOWN_S`（120）秒，只罰那一隻，不停全隊。
- **權重：免費優先**：免費池跑滿 `DCQ_FREE_ROUNDS`（2）輪全敗，或免費模型全在冷卻，才 fallback 到 `DCQ_POOL_PAID`（Go 訂閱模型）；jobfile 標 `PAID=1`。設空＝永不動用。
- **per-model 併發槽**：每隻最多 `DCQ_MODEL_MAX`（3）張，滿了分給下一隻。
- **watchdog**：`.out` 靜默 ≥ `DCQ_STALL_S`（200）秒 → 殺掉、冷卻計數＋1、換下一隻。單隻模型一次嘗試超過 `DCQ_ATTEMPT_MAX`（600）秒 → 同樣殺掉、冷卻計數＋1、換下一隻（一直有輸出的無限迴圈不會觸發停滯，靠這道換手）。工單總時限 `DCQ_JOB_MAX`（2700）秒，超過就殺但不罰模型、不換。最大靜默間隔記在 `~/.dcq/logs/gaps.tsv`，收緊門檻前先看它。
- `dcq status` 列出每隻模型的 `busy=n/max` 與冷卻剩餘秒數。

## 驗收

**exit code ＝ `wo-verify` 的 rc，不是模型的。** 模型回報 DONE 一律不算數。

```bash
dc <task.md> <cwd>; echo "rc=$?"   # 0 = 驗收重跑 K 次全過
```

反向也成立：驗收斷言不可能成立時，即使模型正常執行完，dc 仍回非 0。

三道防假成功的閘，各有自己的退出碼：

| rc | 意思 | 主 session 要做的事 |
|---|---|---|
| 0 | 驗收連過 `DC_VERIFY_K` 次（預設 2） | 結案 |
| 2（派工前） | do-nothing 負向對照失敗：驗收未動工就通過 | 改驗收寫成真斷言，或加 `NEG-CONTROL: n/a` |
| 3 | 驗收區塊與 pin 不一致＝執行人動了評分器 | 看 diff，查他有沒有真的做事，**不要**改 pin 再跑一次 |
| 其它 | 驗收腳本首個失敗指令的 rc | 照常重派或自己修 |

## 已知坑（實測）

- **`--auto` 必開**：`permission.bash="ask"` 在 headless 下會被自動拒絕 —— 沒這道模型**一跑 bash 就死**（連 `ls` 都過不了），只能靠 write/edit 硬寫。dc 已內建，`DC_NO_AUTO=1` 可關。
- **`--pure`**：同一模型 4.5s vs 16s（`agentpet.js` 外掛佔 ~11s）。opencode v2 已移除，dc 依 `run --help` 自動決定帶不帶。
- **`--standalone`（v2）**：v2 預設走共用背景服務，卡死時零輸出；dc 在 v2 一律帶，額度／限流偵測也靠它帶出的 ERROR log。
- **cd 進工作目錄 + `-f` 必給**：任務檔常在專案外，dc 先 cd 進工作目錄（1.18.x 另帶 `--dir`）、`-f` 附加任務檔。dc 已內建。
- **message 必須放最前面**：`-f` 是陣列旗標，會把後續位置參數一起當附件路徑吞掉。
- **驗收在工作目錄底下跑**：斷言用相對路徑，在呼叫端 cwd 跑會誤判 FAIL。dc 已處理。
- **免費端點會突然掛**：實測 `ling-3.0-flash-fin-free` 回 `Upstream unavailable`。dc 不做自動 fallback，失敗就回報，換模型由呼叫端決定。
- **模型很慢**：免費池的帳單是 wall-clock 不是 token。單一函式小修 17–20 秒，兩個函式加約束 4 分鐘。長任務不要用 dc。
- **`504 Upstream idle timeout exceeded` 的根因是單輪閒置，不是總時長**（2026-09-30 實測：7 步工單死在 step 4 的 `uv venv`／`uv pip install`）。對策見上面五條第 1、2 點，不要靠重試硬碰。
- **實測穩定度**（2026-09-30，經 zen_shim CLI 路徑，PONG 往返）：`big-pickle` 3.5–4.4s、`zen-space-bunny` 2.5–3.5s、`zen-nemotron` 4–20s，三輪全過；同時段走 OmniRoute 的 `auto/best-free` 三輪全掛、`free-tools` 21–47s 且間歇回 `[404]: 0 endpoints out of 9 requested`。**走 CLI 的穩，走 OmniRoute 的不穩。**

## 不做

- 跨多檔改動、長鏈重構、需要在合理時間內拿到結果的活 → 拆 dcq 或主 session 直接做。
- 沙箱外寫入 → 主 session 直接做；要 agent 多步自主才改派deep。

## 相依

`wo-verify` 與 `deep-lint` 收在本 repo `bin/`，dc／dcq 一律用同目錄那份，不走 PATH（PATH 上的 `wo-verify` 是 deepclaude 的 symlink）。dc 與 deepclaude 互不依賴：2026-10-12 起不再借 `~/.deepclaude/deep-agent/bin`，兩份各自演進；`test/dcq_test.sh` 斷言 `bin/` 不得引用 `~/.deepclaude`。
