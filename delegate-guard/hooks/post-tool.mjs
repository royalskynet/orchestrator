#!/usr/bin/env node
// delegate-guard — PostToolUse／PostToolUseFailure(全部工具)。
//   成功：Read 記即時上下文；Agent(o-worker)／dcq add 確認派出 → 帳本標 launched、解除本段改派要求；S4 大輸出第 2 次建議派。
//   失敗：對應的 proposed 派工標 launch-failed（不算派出）。
// fail-open：任何例外 exit 0。
import fs from 'node:fs';
import { isOff, isMain, onPostTool, onDispatched, log } from './lib.mjs';
import { updateLedger, updateSess, onLaunched, onLaunchFailed, runnerCmd } from './ledger.mjs';

const dispatchedText = (sid, ids) => [
  `delegate-guard：已登記 ${ids.length} 張派工，驗收快照已存。o 完工後（背景派工等完工通知），主 session 要自己重驗，不採信 o 的回報：`,
  ...ids.map((id) => `  ${runnerCmd(sid, id)}`),
  '再跑 `git -C <cwd> diff --stat` 看有沒有超出工單的改動。重驗 rc≠0 就回報失敗並附原始輸出。',
].join('\n');

export function handlePost(payload) {
  const sid = payload.session_id;
  const tool = payload.tool_name;
  if (payload.hook_event_name === 'PostToolUseFailure') {
    updateLedger(sid, (l) => onLaunchFailed(l, { toolUseId: payload.tool_use_id }));
    return null;
  }
  const r = payload.tool_response;
  const launched = updateLedger(sid, (l) => onLaunched(l, { toolUseId: payload.tool_use_id, tool, response: r }));
  const responseChars = typeof r === 'string' ? r.length : JSON.stringify(r ?? '').length;
  return updateSess(sid, (st) => {
    if (launched.length) st = onDispatched(st);
    const o = onPostTool(st, { tool, input: payload.tool_input ?? {}, responseChars });
    if (!launched.length) return { st: o.st, result: o.action };
    return { st: o.st, result: { kind: 'dispatched', via: launched.join(','), text: dispatchedText(sid, launched) } };
  });
}

if (isMain(import.meta.url)) {
  setTimeout(() => process.exit(0), 2500).unref();
  try {
    const payload = JSON.parse(fs.readFileSync(0, 'utf8') || '{}');
    if (isOff() || payload.agent_id || !payload.tool_name) process.exit(0);
    const action = handlePost(payload);
    if (action) log(`${action.kind}\t${action.via}\t${payload.tool_name}`);
    if (action?.kind === 'suggest' || action?.kind === 'dispatched') {
      process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PostToolUse', additionalContext: action.text } }));
    }
  } catch (e) {
    log(`fail-open\tpost\t${String(e?.message ?? e).slice(0, 160)}`);
  }
  process.exit(0);
}
