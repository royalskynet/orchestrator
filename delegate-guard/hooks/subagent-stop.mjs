#!/usr/bin/env node
// delegate-guard — SubagentStop：o-worker 結束 → 帳本對應 agentId 標 terminal。只記帳不輸出：
// 這個事件的 additionalContext／block 會送給子代理本身，不是主 session。結束≠成功，成敗由主 session 重驗判定。
import fs from 'node:fs';
import { isOff, isMain, onWorkerBack, log } from './lib.mjs';
import { updateLedger, updateSess, onSubagentStop, readLedger, anyRunning } from './ledger.mjs';

if (isMain(import.meta.url)) {
  setTimeout(() => process.exit(0), 2500).unref();
  try {
    const payload = JSON.parse(fs.readFileSync(0, 'utf8') || '{}');
    if (!isOff() && payload.agent_type === 'o-worker' && payload.agent_id) {
      const sid = payload.session_id;
      updateLedger(sid, (l) => onSubagentStop(l, { agentId: payload.agent_id }));
      // worker 回來＝帳本沒有還在跑的派工 → 解除「已派未回」，恢復本段計數（issue #2）
      updateSess(sid, (st) => ({ st: st.reroute?.pending && !anyRunning(readLedger(sid)) ? onWorkerBack(st) : st }));
      log(`subagent-stop\t${payload.agent_id}`);
    }
  } catch (e) {
    log(`fail-open\tsubagent-stop\t${String(e?.message ?? e).slice(0, 160)}`);
  }
  process.exit(0);
}
