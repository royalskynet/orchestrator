#!/usr/bin/env node
// delegate-guard — Stop：o 已完工但主 session 沒重驗、驗完又被改、或重驗失敗 → decision:block 提醒。
// 每筆派工最多提醒 2 次（自己記次數，不靠 stop_hook_active——那旗標代表任何 Stop hook 續跑過）。
// 這是提醒機制，不是硬保證：提醒用完就放行，log 留紀錄。
import fs from 'node:fs';
import { isOff, isMain, log } from './lib.mjs';
import { updateLedger, stopCheck } from './ledger.mjs';

if (isMain(import.meta.url)) {
  setTimeout(() => process.exit(0), 4500).unref();
  try {
    const payload = JSON.parse(fs.readFileSync(0, 'utf8') || '{}');
    if (!isOff() && !payload.agent_id) {
      const reason = updateLedger(payload.session_id, (l) => stopCheck(l, payload.session_id));
      if (reason) {
        log(`stop-block\t${reason.split('\n').length - 2} 筆`);
        process.stdout.write(JSON.stringify({ decision: 'block', reason }));
      }
    }
  } catch (e) {
    log(`fail-open\tstop\t${String(e?.message ?? e).slice(0, 160)}`);
  }
  process.exit(0);
}
