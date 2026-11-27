# dispatch-router

## 驗證
禁止在互動 session 跑 `test/run_all.sh` 全量測試；它會序列執行全部 shell tests，watchdog、冷卻與 timeout 模擬包含真實等待，容易卡很久。全量只在使用者明確要求時跑，或移到背景／CI。

改完程式跑受影響的最小測試，全綠才算完成：
```bash
bash test/<相關>_test.sh
```
沒有對應測試時，補一個最小回歸測試或明說未驗證。
