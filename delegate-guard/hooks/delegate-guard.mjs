#!/usr/bin/env node
// delegate-guard — PreToolUse(全部工具)。順序：派工驗收閘 → 已驗收作廢檢查 → 訊號（S1/S2/S3/S5）與改派三類。
//   建議派＝additionalContext，不擋；直接改派＝deny，直到 o 真的派出（PostToolUse 確認）或明示自做，每段最多擋 3 次；
//   無法派＝不擋，說一次原因。派給 o 的工單沒有驗收區塊 → deny 要求補。
// 起因 fixindex 11411；設計 DESIGN-v0.2.md＋README「v0.3」。開關 /deguard（~/.claude/delegate-guard.off 存在＝off，每次重讀）。
// 子代理內的工具呼叫（payload 帶 agent_id）不計、不閘——O 內部怎麼派不管。fail-open：髒 payload、例外 → exit 0。
// 測試：node ~/dev/delegate-guard/hooks/test/delegate-guard.test.mjs
import fs from 'node:fs';
import { isOff, isMain, onPreTool, onWorkerBack, contextTokens, log } from './lib.mjs';
import { gateDispatch, updateLedger, updateSess, invalidate, readLedger, anyRunning } from './ledger.mjs';

export function preToolOutput(action) {
  if (action?.kind === 'reroute' || action?.kind === 'gate') {
    return { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: action.text } };
  }
  if (action?.kind === 'suggest' || action?.kind === 'note') {
    return { hookSpecificOutput: { hookEventName: 'PreToolUse', additionalContext: action.text } };
  }
  return null;
}

export function handlePre(payload) {
  const sid = payload.session_id;
  const ev = { tool: payload.tool_name, input: payload.tool_input ?? {}, cwd: payload.cwd ?? '', toolUseId: payload.tool_use_id ?? '' };
  const gate = gateDispatch(ev);
  if (gate?.deny) return { kind: 'gate', via: 'accept-gate', text: gate.deny };
  updateLedger(sid, (l) => {
    if (gate?.entries) l.pending.push(...gate.entries);
    invalidate(l, ev);
  });
  const ctx = typeof payload.transcript_path === 'string' ? contextTokens(payload.transcript_path) : null;
  return updateSess(sid, (st) => {
    // dcq 沒有 worker-return 事件：pending 期間每個 PreToolUse 看帳本，沒有還在跑的派工就恢復計數
    if (st.reroute?.pending && !anyRunning(readLedger(sid))) st = onWorkerBack(st);
    const r = onPreTool(st, { ...ev, ctx, sid });
    return { st: r.st, result: r.action };
  });
}

if (isMain(import.meta.url)) {
  setTimeout(() => process.exit(0), 4500).unref();
  try {
    const payload = JSON.parse(fs.readFileSync(0, 'utf8') || '{}');
    if (isOff() || !payload.tool_name || payload.agent_id) process.exit(0);
    const action = handlePre(payload);
    if (action) log(`${action.kind}${action.cls ? `/${action.cls}` : ''}\t${action.via}\t${payload.tool_name}\t${String(payload.tool_input?.command ?? payload.tool_input?.file_path ?? payload.tool_input?.description ?? '').slice(0, 100).replace(/\s+/g, ' ')}`);
    const out = preToolOutput(action);
    if (out) process.stdout.write(JSON.stringify(out));
  } catch (e) {
    log(`fail-open\tpre\t${String(e?.message ?? e).slice(0, 160)}`);
  }
  process.exit(0);
}
