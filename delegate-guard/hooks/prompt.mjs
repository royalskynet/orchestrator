#!/usr/bin/env node
// delegate-guard — UserPromptSubmit：開新的一段（計數歸零、使用者原話全文存 goal 檔給全權派工單引用），S6 任務層打分。
//   命中（≥S6_HIT）→ 建議派；剛好平手分 → 問 Laya，答 delegate 才建議派；判不下、503、逾時 → 放行不出聲。
// fail-open：任何例外 exit 0。
import fs from 'node:fs';
import path from 'node:path';
import { isOff, isMain, onPrompt, scoreTask, suggestText, cascadeUrl, askSystemOne, goalFile, log, S6_HIT, S6_TIE } from './lib.mjs';
import { updateSess } from './ledger.mjs';

export async function judgePrompt(prompt, { url = cascadeUrl(), fetchImpl = fetch } = {}) {
  const { score, hits } = scoreTask(prompt);
  if (score >= S6_HIT) return { s6: true, via: `S6 ${score} ${hits.join(',')}` };
  if (score === S6_TIE && url) {
    try {
      const v = await askSystemOne(url, prompt, fetchImpl);
      if (v === 'delegate') return { s6: true, via: `S6 ${score} laya` };
      return { s6: false, via: `S6 ${score} laya-${v ?? 'abstain'}` };
    } catch (e) {
      return { s6: false, via: `S6 ${score} laya-error ${String(e?.message ?? e).slice(0, 60)}` };
    }
  }
  return { s6: false, via: `S6 ${score}` };
}

if (isMain(import.meta.url)) {
  setTimeout(() => process.exit(0), 5500).unref();
  try {
    const payload = JSON.parse(fs.readFileSync(0, 'utf8') || '{}');
    const sid = payload.session_id;
    const prompt = String(payload.prompt ?? '');
    updateSess(sid, (st) => ({ st: onPrompt(st, prompt) }));
    fs.mkdirSync(path.dirname(goalFile(sid)), { recursive: true });
    fs.writeFileSync(goalFile(sid), prompt);
    if (isOff()) process.exit(0);
    const r = await judgePrompt(prompt);
    updateSess(sid, (st) => ({ st: { ...st, s6: r.s6 } }));
    if (r.s6) {
      log(`suggest\t${r.via}\tprompt\t${prompt.slice(0, 100).replace(/\s+/g, ' ')}`);
      process.stdout.write(JSON.stringify({
        hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: suggestText(`任務層 ${r.via}`) },
      }));
    }
  } catch (e) {
    log(`fail-open\tprompt\t${String(e?.message ?? e).slice(0, 160)}`);
  }
  process.exit(0);
}
