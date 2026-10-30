---
name: o
description: Orchestrator：把工單派給本機免費／訂閱 LLM 當執行人（dc 單張、dcq 佇列＋多層 fallback），完工由 wo-verify 機械判定。說「派o」「派 o」「派工」時用；「派of」＝只用免費、「派os」＝訂閱優先、「派o <模型名>」＝該模型先派（舊稱派dr／派drf／派drs 同義）。「派deep」走 deep skill，不是這裡。
---

# Orchestrator（dc／dcq）

派法、層級順序、免費兩層、每日維護、全部環境變數都在 `~/dev/dispatch-router/bin/dcq help`（約 9KB 一頁），不憑記憶。完成定義＝wo-verify 通過，模型自述 DONE 不算數。

## 安全

- **opencode free 層（Zen、`opencode-go/*-free`）只准經 opencode CLI（`opencode run`／`dc`／`dcq`）呼叫，禁止 API 直打。** Zen 沒回應不判失效、不重試探測：會被判濫用、封整個 IP。能不能用看 `dcq rank`。
- 開 API 層（`DCQ_ALLOW_API=1`，按量扣錢）前先問使用者；訂閱層是定額，不算花錢。
- `~/.dcq/.ALARM` 或 `freecheck` 擋單＝免費額度異常。確認是誤報才 `DC_FREECHECK=off` 或刪 `.ALARM`。

## 誰做

- 主 session 5 分鐘內做得完就自己做；超過就主動派，不問、不等答覆，`dcq plan` 輸出附在回報。
- 需要判斷力（設計取捨、找根因）→ 主 session。
- 要寫 `~/.claude/**`、`.git/config`、launchd，或要 `GH_TOKEN`（gh／push／PR）→ 主 session 直接做；需 agent 多步自主才派deep。
- 其餘一律走 dcq，單張也是：只有 dcq 有 fallback 鏈與逾時換手。裸 `dc` 只跑一隻模型，用於指定模型做實驗。

## 派法

| 觸發詞 | `DCQ_ORDER` | 順序 |
|---|---|---|
| 派o／派工 | `default` | 免費 → 懲罰 → 兜底 → 冷宮 → 訂閱（API 預設關） |
| 派of | `free` | 只用免費的層，全敗就失敗 |
| 派os | `sub` | 訂閱先，用盡回免費，API 墊底 |

「派o <名稱>」→ plan 與 add 都多帶 `DCQ_PREFER=<名稱>`（子字串、不分大小寫，只影響免費層排序）。`DCQ_ORDER`／`DCQ_PREFER` 在 `dcq add` 時寫進 job 檔，事後改要重新 add。

## Cheat sheet

```text
DCQ_ORDER=<default|free|sub> dcq plan <task.md>...            # 印難度（預設 mid；DCQ_TRIAGE=1 才由 Laya 判）與會走的層，不入列
DCQ_ORDER=<序> dcq add <task.md 絕對路徑> <cwd> <easy|mid|hard> # 難度照 plan；印 job id，全部收起來
dcq start [-j N=4]                                             # 從 agent session 用這個（tmux 背景，上限 8）
dcq wait <id>... [--timeout S]                                 # Bash run_in_background 跑；rc 0 全過／1 有失敗／124 逾時／3 沒 runner
dcq status                                                     # 成敗總表、各模型 busy 與冷卻
dcq cancel <job-id>                                            # 停一張；不要自己 kill，會被當成模型失敗換下一隻重跑
dc <task.md 絕對路徑> [cwd] [--agent <name>] [-- <opencode run 旗標>...]
```

- 派完立刻掛 `dcq wait`，不用 ScheduleWakeup／Monitor／sleep 輪詢。`dcq wait` 回 3＝忘了 `dcq start`。
- 一次多張別自己開 N 個 `dc`：共用 cwd 會互相汙染驗收，dcq 會做 cwd 互斥。

Hard shapes：

```text
wo-verify <task.md> --dry          # 旗標在檔名之後（放前面會 exit 2）
~/dev/dispatch-router/bin/deep-lint <task.md>   # PATH 上的 deep-lint 是 deepclaude 那份
```

Index：`dcq run [-j N]`（前景，呼叫端死就跟著死）`dcq rank [easy|mid|hard]` `dcq rescan` `dcq doctor [--fix]` `dcq clear` `dcq help`；`freepool-guard scan|status|pool|verify|guard|propose|probe|daily`（`--help`）；`zen-gate until|check|trip|ok|halfopen`；`freecheck`；`dc|wo-verify|deep-lint --help`；`wo-verify <task.md> --dump|--pinned <script>`。

## 工單

格式契約（一個驗收 shell 區塊、區塊外「預期：」行、`## 禁止` 段、≤40 行、標題用 `##`）見 `~/.claude/skills/deep/SKILL.md` 的「任務檔」段。`dcq add` 前會跑 deep-lint 與 `wo-verify --dry`，不過就不入列。

免費池的限制是逾時、無 prompt caching、可用性波動，工單照這幾條寫：

1. **單輪不得長時間無輸出**：`504 Upstream idle timeout` 是閒置逾時。`npm ci`／`uv pip install`／大型下載由呼叫端先跑完。
2. **一工單一目標**：多步就拆成多張，每張自帶驗收，斷了只重派那張。
3. **驗收是真斷言，未動工前必須失敗**：wo-verify 只看 shell 區塊的 exit code，「預期：」行不檢查；比對輸出寫 `[ "$(...)" = "..." ]`。確認既有狀態型的工單加一行 `NEG-CONTROL: n/a`。
4. **冪等**：斷言寫「已存在就過」，重派不破壞前一輪。
5. **context 放檔案**：給絕對路徑讓模型自己讀，不把檔案內容貼進工單。
6. **指定模型用單一 dc_id**（`DC_FREE_MODEL`），不用 `omniroute/auto` 類路由名。

不滿足就拆成多張單步工單，不是退回主 session。

## 讀結果

| dc rc | 意思 | 主 session 做 |
|---|---|---|
| 0 | 驗收連過 `DC_VERIFY_K`（預設 2）次 | 結案 |
| 2（派工前） | 工單契約錯，或負向對照失敗（驗收未動工就過） | 改成真斷言或加 `NEG-CONTROL: n/a` |
| 3 | 驗收區塊與派工前 pin 不一致＝執行人改了評分器 | 看 diff 查他有沒有真做事，不要改 pin 重跑 |
| 75 | 同 cwd 已有 dc／dcq 在跑 | 換目錄或 `DC_LOCK_WAIT=<秒>`，不是上游壞 |
| 其它 | 驗收首個失敗指令的 rc | 看 `wo-verify FAIL line N` 那行，重派或自己修 |

只過第一次、第二次失敗＝flaky，不結案。失敗細節看 `dcq status` 與 `~/.dcq/logs/`。

## 查哪裡

- 層級、freepool、env 預設值、每日維護 → `dcq help`
- 模型排名、各層名單 → `dcq rank`；清冊 `catalog/models.tsv`、併發上限 `catalog/providers.tsv`
- 單張 `dc` 實驗、dc 環境變數、Zen／Go 前綴分辨 → [references/dc.md](references/dc.md)
- Go HTTP lane、架構 → repo `README.md`
