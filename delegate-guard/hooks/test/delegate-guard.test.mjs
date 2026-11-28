// node ~/dev/delegate-guard/hooks/test/delegate-guard.test.mjs → ALL PASS
// 用真的 wo-verify（O 的唯讀依賴）；state 與 ~/.dcq 都指到暫存目錄。
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dg-test-'));
import os from 'node:os';
process.env.DEGUARD_STATE = `${tmp}/state`;
process.env.DEGUARD_LOG = `${tmp}/log`;
process.env.DEGUARD_OFF_FILE = `${tmp}/off`;
process.env.DEGUARD_DCQ_HOME = `${tmp}/dcq`;
process.env.DECIDE_CASCADE_FILE = `${tmp}/cascade.json`;
for (const d of ['pending', 'running', 'done', 'failed']) fs.mkdirSync(`${tmp}/dcq/${d}`, { recursive: true });

const L = await import('../lib.mjs');
const G = await import('../ledger.mjs');
const { judgePrompt } = await import('../prompt.mjs');
const { preToolOutput, handlePre } = await import('../delegate-guard.mjs');
const { handlePost } = await import('../post-tool.mjs');
const {
  hardKeyword, isReadOnly, isDispatchedCmd, isRunnerCmd, selfReason, scoreTask,
  newState, onPrompt, onPreTool, onPostTool, onDispatched, classify, contextTokens,
  countsTowardS1,
} = L;

// —— S5 硬關鍵字與唯讀 ——
for (const c of ['pnpm update -r --latest', 'npm install dompurify@latest', 'pip3 install -r requirements.txt', 'cargo update',
  'npx vitest run', 'pnpm -r test', 'npm test', 'pytest', 'pytest tests/', 'rsync -a src/ dst/', 'echo ok; npm install', 'ls && npm test']) {
  assert.ok(hardKeyword(c), `S5 should hit: ${c}`);
}
for (const c of ['npx vitest run src/a.test.ts', 'npx vitest run -t "login"', 'pnpm update --help | head', 'pytest tests/test_a.py::test_x',
  'pytest tests/test_one.py', 'grep -rn "pnpm update" docs/', 'sed -i "s/a/b/" x.ts', 'make build', 'for f in *.ts; do wc -l "$f"; done']) {
  assert.equal(hardKeyword(c), '', `S5 should not hit: ${c}`);
}
assert.equal(isReadOnly('git status --short'), true);
assert.equal(isReadOnly('ls | head -3 && git log -1'), true);
assert.equal(isReadOnly('echo ok; npm install'), false, '複合指令每段都要唯讀');
assert.equal(isReadOnly('echo x > out.txt'), false, '重導向寫檔不是唯讀');
assert.equal(isReadOnly('grep foo a 2>/dev/null'), true);
assert.equal(isReadOnly('git commit -m x'), false);
assert.equal(isDispatchedCmd('DCQ_ORDER=default dcq plan /tmp/t.md'), true);
assert.equal(isDispatchedCmd('cd ~/dev/dispatch-router && bash test/a.sh'), false);
assert.equal(selfReason('pnpm install # deguard:self 要看 lockfile 衝突'), '要看 lockfile 衝突');

// —— S6 ——
assert.ok(scoreTask('把這 12 個檔全部照範本改').score >= 3);
assert.equal(scoreTask('全部搬到新目錄').score, 3);
assert.equal(scoreTask('每個檔都看一下').score, 2);
assert.ok(scoreTask('審查這三項：\n- 架構\n- 安全\n- 效能').score < 3, '判斷型清單不算機械任務');

// —— 小工具 ——
const run = (st, n, ev) => { const acts = []; for (let i = 0; i < n; i++) { const r = onPreTool(st, ev(i)); st = r.st; acts.push(r.action); } return { st, acts }; };
const seg = (p = '修一下') => onPrompt(newState(), p);
const bashN = (i) => ({ tool: 'Bash', input: { command: `make step${i}` }, cwd: '/x' });

// S1：10 建議；呼叫數本身不再改派（issue #2，改派只認 S3／S5 這種內容訊號）
{
  const { st, acts } = run(seg(), 28, bashN);
  assert.equal(acts[8], null);
  assert.equal(acts[9].kind, 'suggest');
  assert.equal(preToolOutput(acts[9]).hookSpecificOutput.permissionDecision, undefined, '建議派不擋');
  for (const [i, action] of acts.slice(10).entries()) assert.equal(action, null, `S1 第 ${i + 11} 次不得改派`);
  assert.equal(st.reroute, null);
}
// 派出後解除
{
  let { st } = run(seg(), 18, bashN);
  st = onDispatched(st);
  const r = onPreTool(st, bashN(99));
  assert.notEqual(r.action?.kind, 'reroute');
}
// 唯讀照放
{
  let { st } = run(seg(), 18, bashN);
  assert.equal(onPreTool(st, { tool: 'Bash', input: { command: 'git status' } }).action?.kind ?? null, null);
  assert.equal(onPreTool(st, { tool: 'Read', input: { file_path: '/x/a' } }).action?.kind ?? null, null);
}
// verify runner 在 plugin cache 版路徑也要認得（0.3.3 實機缺陷）
{
  assert.equal(isRunnerCmd('node /Users/x/.claude/plugins/cache/delegate-guard/delegate-guard/0.3.3/scripts/verify.mjs sid id'), true);
  assert.equal(isRunnerCmd('node /Users/x/dev/delegate-guard/scripts/verify.mjs sid id'), true);
}
// S2：高上下文把建議線提前；呼叫數本身同樣不改派
{
  const { acts } = run(seg(), 12, (i) => ({ ...bashN(i), ctx: 150_000 }));
  assert.equal(acts[5].kind, 'suggest');
  assert.equal(acts[10], null);
}
// 子代理：只計之後
{
  let { st } = run(seg(), 20, bashN);
  st = onPreTool(st, { tool: 'Agent', input: { subagent_type: 'Explore' } }).st;
  assert.equal(st.calls, 0);
}
// 三類分類
{
  const base = { ...seg(), s6: true };
  assert.equal(classify({ via: 'S5 x', tool: 'Bash', input: { command: 'npm test' }, st: base }).cls, 'full');
  assert.equal(classify({ via: 'S5 x', tool: 'Bash', input: { command: 'npm test' }, st: seg() }).cls, 'partial', '單一動作訊號不擴張成全權');
  assert.equal(classify({ via: 'S1', tool: 'Bash', input: { command: 'make' }, st: base }).cls, 'partial');
  assert.equal(classify({ via: 'S5 x', tool: 'Bash', input: { command: 'npm install # deguard:self 看衝突' }, st: base }).cls, 'none');
  assert.equal(classify({ via: 'S5 x', tool: 'Bash', input: { command: 'npm test' }, st: { ...base, prompt: '改 ~/.claude/settings.json 後跑測試' } }).cls, 'none', '禁區優先');
  assert.equal(classify({ via: 'S3', tool: 'Edit', input: { file_path: '/x/a' }, st: { ...seg(), read: ['/x/a'] } }).cls, 'none');
  assert.equal(classify({ via: 'S3', tool: 'Edit', input: { file_path: '/x/a' }, st: { ...base, read: ['/x/a'] } }).cls, 'full', '任務層命中就不算即時上下文');
}
// 無法派：說一次，不擋
{
  const st = seg('改 LCT 報表');
  let r = onPreTool(st, { tool: 'Bash', input: { command: 'npm test' } });
  assert.equal(r.action.kind, 'note');
  assert.equal(preToolOutput(r.action).hookSpecificOutput.permissionDecision, undefined);
  r = onPreTool(r.st, { tool: 'Bash', input: { command: 'npm test' } });
  assert.equal(r.action.kind, 'allow');
}
// 即時上下文：Read 成功（PostToolUse）才記，且每段重置
{
  let st = seg();
  st = onPostTool(st, { tool: 'Read', input: { file_path: '/x/a.ts' } }).st;
  assert.deepEqual(st.read, ['/x/a.ts']);
  st = onPrompt(st, '下一題');
  assert.deepEqual(st.read, []);
  assert.equal(onPreTool(seg(), { tool: 'Read', input: { file_path: '/x/b' } }).st.read.length, 0, 'PreToolUse 不記 Read');
}
// S3
{
  const { acts } = run(seg(), 10, (i) => ({ tool: 'Write', input: { file_path: `/x/f${i}.md` } }));
  assert.equal(acts[9].kind, 'reroute');
}
// S4
{
  let r = onPostTool(seg(), { responseChars: 50_000 }); assert.equal(r.action, null);
  r = onPostTool(r.st, { responseChars: 50_000 }); assert.equal(r.action.kind, 'suggest');
}
// S2 量測
{
  const tf = `${tmp}/t.jsonl`;
  fs.writeFileSync(tf, [{ type: 'assistant', message: { usage: { input_tokens: 5, cache_read_input_tokens: 120_000, cache_creation_input_tokens: 3 } } }].map((x) => JSON.stringify(x)).join('\n'));
  assert.equal(contextTokens(tf), 120_008);
}
// S6 Laya 平手
{
  const offline = async () => { throw new Error('x'); };
  const resp = (status, noul) => async () => ({ ok: status === 200, status, json: async () => ({ answers: { delegate: { noul } } }) });
  assert.equal((await judgePrompt('每個檔都看一下', { url: 'http://127.0.0.1:1', fetchImpl: resp(200, 0.9) })).s6, true);
  assert.equal((await judgePrompt('每個檔都看一下', { url: 'http://127.0.0.1:1', fetchImpl: resp(503) })).s6, false);
  assert.equal((await judgePrompt('每個檔都看一下', { url: 'http://127.0.0.1:1', fetchImpl: offline })).s6, false);
}

// S1 只量非唯讀動作（2026-11-04）：30 次唯讀 Bash 不累加、不觸發；混一個寫檔算一次
{
  const ro = ['ls ~/dev', 'cat README.md', 'head -3 x', 'tail -3 x', 'grep -rn foo .', 'rg foo', 'find /tmp -name x', 'jq . x.json',
    'wc -l x', 'stat x', 'git status', 'git log -1', 'git diff', 'git show HEAD', 'which node', 'ls --help'];
  let st = seg();
  for (let i = 0; i < 30; i++) {
    const r = onPreTool(st, { tool: 'Bash', input: { command: ro[i % ro.length] }, cwd: '/x' });
    st = r.st;
    assert.equal(r.action, null, `唯讀不該觸發：${ro[i % ro.length]}`);
  }
  assert.equal(st.calls, 0, '30 次唯讀 Bash 不累加 st.calls');
  st = onPreTool(st, { tool: 'Read', input: { file_path: '/x/a' } }).st;
  st = onPreTool(st, { tool: 'Grep', input: { pattern: 'x' } }).st;
  st = onPreTool(st, { tool: 'Glob', input: { pattern: '*' } }).st;
  assert.equal(st.calls, 0, 'Read/Grep/Glob 不累加');
  st = onPreTool(st, { tool: 'Bash', input: { command: 'echo x > /tmp/f' }, cwd: '/x' }).st;
  assert.equal(st.calls, 1, '寫檔 Bash 要算一次');
}
assert.equal(countsTowardS1('Bash', { command: 'find . -name x -delete' }), true, 'find -delete 不算唯讀');
assert.equal(countsTowardS1('Bash', { command: 'find . -exec rm {} +' }), true, 'find -exec 不算唯讀');
// 2026-11-04 補洞：會寫檔／執行東西的指令不得算唯讀（codex 驗收 7 條＋旁例）
for (const c of ['echo $(touch ${tmp}/dg-proof)', 'git branch -D topic', 'git diff --output=${tmp}/dg-proof', 'echo x 1>${tmp}/dg-proof',
  'rg x --pre=./mutator', 'curl -sS -o /dev/null https://example.com -o ${tmp}/dg-proof https://example.com', 'sed -i s/a/b/ file # --help',
  'echo x &>${tmp}/dg-proof', 'echo x >>${tmp}/dg-proof', 'cat <(touch ${tmp}/dg-proof)', '`touch ${tmp}/dg-proof`', 'git diff --output-indicator-new=x',
  'rg x --pre ./mutator', 'ls --help > ${tmp}/dg-proof', 'echo hi; npm install',
  // 解譯器可任意寫檔，不算唯讀
  'python3 -c "open(\'f\',\'w\')"', 'node -e "process.exit(1)"', 'node -e 0', 'python3 -c 0',
  // 任意 fd 的寫入重導向都算寫入，只有 /dev/null 例外
  'jq -n input_filename 3>f', 'jq . a 3>f', 'jq . a 4>>f']) {
  assert.equal(isReadOnly(c), false, `不得算唯讀：${c}`);
}
for (const c of ['ls', 'cat README.md', 'git status', 'find . -name x', 'ls --help', 'git log --help', 'rg foo .', 'ls > /dev/null', 'echo x 2>&1 >/dev/null', 'grep foo a 2>/dev/null', 'jq . a 2>/dev/null', 'node -v', 'python3 -V']) {
  assert.equal(isReadOnly(c), true, `應算唯讀：${c}`);
}

// —— 派工驗收閘 ——
const work = `${tmp}/work`; fs.mkdirSync(work);
const ticketText = (body) => `## 任務\n產生 out.txt\n工作目錄：${work}\n\n## 驗收\n\`\`\`bash\n${body}\n\`\`\`\n`;
const GOOD = `test -f ${work}/out.txt && grep -q done ${work}/out.txt`;
{
  const ag = (prompt) => G.gateDispatch({ tool: 'Agent', input: { subagent_type: 'o-worker', prompt }, cwd: '/elsewhere', toolUseId: 'tu1' });
  assert.ok(ag('幫我把 out.txt 生出來').deny, '沒驗收區塊要擋');
  assert.ok(ag(ticketText('echo ok')).deny, '只有 echo 要擋');
  assert.ok(ag(ticketText('true')).deny);
  assert.ok(ag(ticketText(`${GOOD} || true`)).deny, '|| true 要擋');
  assert.ok(ag(ticketText('test 1 = 1')).deny, '恆真比較要擋');
  assert.ok(ag(ticketText('if [ ; then')).deny, '語法錯要擋');
  const ok = ag(ticketText(GOOD));
  assert.equal(ok.entries.length, 1);
  assert.equal(ok.entries[0].cwd, work, '從工單抓工作目錄');
  assert.equal(ag(`工作目錄：/tmp/wo-x（不存在就建）。\n${ticketText(GOOD)}`).entries[0].cwd, '/tmp/wo-x', '全形括號／句號不算路徑');
  assert.equal(G.gateDispatch({ tool: 'Agent', input: { subagent_type: 'Explore', prompt: 'x' } }), null, '非 o-worker 不閘');
  assert.equal(G.gateDispatch({ tool: 'Bash', input: { command: 'ls' } }), null);
  assert.ok(G.gateDispatch({ tool: 'Bash', input: { command: 'dcq add "$D/t.md" /x' } }).deny, 'dcq add 變數路徑要擋');
  const tk = `${tmp}/t1.md`; fs.writeFileSync(tk, ticketText(GOOD));
  const d = G.gateDispatch({ tool: 'Bash', input: { command: `DCQ_ORDER=default dcq add ${tk} ${work} easy` }, toolUseId: 'tu2' });
  assert.equal(d.entries[0].ticket, tk);
  assert.equal(d.entries[0].cwd, work);
}

{
  const sid = 'sess-legacy-pin';
  const script = 'false || echo "tests failed"\n';
  const ticket = `${tmp}/legacy.md`, snapshot = `${tmp}/legacy.sh`;
  fs.writeFileSync(ticket, ticketText(script.trimEnd()));
  fs.writeFileSync(snapshot, script);
  G.updateLedger(sid, (l) => l.pending.push({
    id: 'legacy', kind: 'agent', status: 'terminal', ticket, snapshot, cwd: work,
    hash: createHash('sha256').update(script).digest('hex'),
  }));
  const v = G.runVerify(sid, 'legacy');
  assert.equal(v.rc, 1, v.out);
  assert.match(v.out, /吞掉失敗/);
  assert.equal(G.readLedger(sid).pending[0].verified.rc, 1);
}

// —— 生命週期：派出、完工、重驗、Stop ——
const sid = 'sess-life';
const pre = (tool, input, toolUseId) => handlePre({ session_id: sid, tool_name: tool, tool_input: input, tool_use_id: toolUseId, cwd: work });
const post = (tool, input, toolUseId, tool_response, ev = 'PostToolUse') => handlePost({ session_id: sid, hook_event_name: ev, tool_name: tool, tool_input: input, tool_use_id: toolUseId, tool_response });
const ledger = () => G.readLedger(sid);
{
  // 兩張背景派工，逆序完工：用 agentId 配，不靠順序
  const inA = { subagent_type: 'o-worker', prompt: ticketText(GOOD) };
  assert.equal(pre('Agent', inA, 'tA').kind, 'allow');
  assert.equal(pre('Agent', inA, 'tB').kind, 'allow');
  assert.equal(ledger().pending.filter((p) => p.status === 'proposed').length, 2);
  const pa = post('Agent', inA, 'tA', { status: 'async_launched', agentId: 'agA' });
  assert.equal(pa.kind, 'dispatched');
  assert.match(pa.text, /scripts\/verify\.mjs sess-life a/);
  post('Agent', inA, 'tB', { status: 'async_launched', agentId: 'agB' });
  G.updateLedger(sid, (l) => G.onSubagentStop(l, { agentId: 'agB' }));
  const [A, B] = ledger().pending;
  assert.equal(A.status, 'launched');
  assert.equal(B.status, 'terminal');
  // 重複的 PostToolUse 不重複消耗
  assert.equal(post('Agent', inA, 'tA', { status: 'async_launched', agentId: 'agA' })?.kind ?? null, null);
  // 還沒完工：verify 回 75，Stop 不擋 A
  assert.equal(G.runVerify(sid, A.id).rc, 75);
  // B 完工未重驗：Stop 擋，附重驗指令
  let reason = G.updateLedger(sid, (l) => G.stopCheck(l, sid));
  assert.match(reason, new RegExp(B.id));
  assert.doesNotMatch(reason, new RegExp(A.id));
  // 成果還沒做出來 → 重驗失敗並記錄
  const v1 = G.runVerify(sid, B.id);
  assert.notEqual(v1.rc, 0);
  reason = G.updateLedger(sid, (l) => G.stopCheck(l, sid));
  assert.match(reason, /重驗失敗/);
  // 每筆最多提醒 2 次
  assert.equal(G.updateLedger(sid, (l) => G.stopCheck(l, sid)), '');
  // 做出成果 → 重驗通過
  fs.writeFileSync(`${work}/out.txt`, 'done\n');
  G.updateLedger(sid, (l) => { l.pending[1].reminders = 0; });
  assert.equal(G.runVerify(sid, B.id).rc, 0);
  assert.equal(G.updateLedger(sid, (l) => G.stopCheck(l, sid)), '');
  // 驗完又在 cwd 寫檔 → 作廢，要重驗；git commit 不算
  pre('Bash', { command: 'git commit -qm x' }, 'tc');
  assert.equal(ledger().pending[1].stale, false);
  // cd＋唯讀、heredoc 寫到 cwd 以外的絕對路徑 → 不算改 cwd（10-28 重驗迴圈）
  pre('Bash', { command: `cd ${work} && find . -newer out.txt 2>/dev/null | head` }, 'tcd');
  pre('Bash', { command: `cat >> ${tmp}/elsewhere.md <<'EOF'\n## note\n- npm install 也只是內文\nEOF` }, 'thd');
  pre('Bash', { command: `echo x >> ~/notes.md` }, 'tho');
  assert.equal(ledger().pending[1].stale, false, 'cd 與寫到 cwd 外不該作廢');
  pre('Bash', { command: `cat >> ${work}/out.txt <<'EOF'\nx\nEOF` }, 'thw');
  assert.equal(ledger().pending[1].stale, true, 'heredoc 寫進 cwd 要作廢');
  G.updateLedger(sid, (l) => { l.pending[1].stale = false; });
  pre('Bash', { command: `echo x > rel.txt` }, 'thr');
  assert.equal(ledger().pending[1].stale, true, '相對路徑重導向＝寫 cwd');
  G.updateLedger(sid, (l) => { l.pending[1].stale = false; });
  pre('Bash', { command: `cd ${work} && npm install` }, 'tni');
  assert.equal(ledger().pending[1].stale, true, 'cd 後跑非唯讀指令仍作廢');
  G.updateLedger(sid, (l) => { l.pending[1].stale = false; });
  pre('Edit', { file_path: `${work}/out.txt` }, 'te');
  assert.equal(ledger().pending[1].stale, true);
  assert.match(G.updateLedger(sid, (l) => G.stopCheck(l, sid)), /驗過之後 cwd 又被改/);
  // 快照被改 → 3
  fs.chmodSync(B.snapshot, 0o644);   // 快照寫完即 0444（d60256a），模擬竄改者先 chmod
  fs.appendFileSync(B.snapshot, '\ntrue\n');
  { const v = G.runVerify(sid, B.id); assert.equal(v.rc, 3); assert.match(v.out, /快照被改/, 'hash 檢查先於 wo-verify'); }
  // cwd 不存在 → 66＋原因，不是無聲的 124
  { const s = B.snapshot; const keep = fs.readFileSync(s, 'utf8').replace(/\ntrue\n$/, '');
    fs.writeFileSync(s, keep);
    G.updateLedger(sid, (l) => { l.pending[1].cwd = `${work}（不存在就建）`; });
    const v = G.runVerify(sid, B.id); assert.equal(v.rc, 66); assert.match(v.out, /cwd 不存在/);
    G.updateLedger(sid, (l) => { l.pending[1].cwd = work; }); }
  // SubagentStop 先於 PostToolUse（孤兒）→ 之後補配
  pre('Agent', inA, 'tC');
  G.updateLedger(sid, (l) => G.onSubagentStop(l, { agentId: 'agC' }));
  post('Agent', inA, 'tC', { status: 'async_launched', agentId: 'agC' });
  assert.equal(ledger().pending.find((p) => p.agentId === 'agC').status, 'terminal');
  // 前台完成
  pre('Agent', inA, 'tD');
  post('Agent', inA, 'tD', { status: 'completed', agentId: 'agD' });
  assert.equal(ledger().pending.find((p) => p.agentId === 'agD').status, 'terminal');
  // 派工失敗 → launch-failed，Stop 不管
  pre('Agent', inA, 'tE');
  post('Agent', inA, 'tE', null, 'PostToolUseFailure');
  assert.equal(ledger().pending.find((p) => p.toolUseId === 'tE').status, 'launch-failed');
}
{
  // dcq 直派：job 檔 TASK= 配工單；running → done 才算完工；執行人改了工單驗收 → --pinned 抓到
  const sid2 = 'sess-dcq';
  const tk = `${tmp}/t2.md`; fs.writeFileSync(tk, ticketText(`grep -q done ${work}/out.txt`));
  const cmd = `dcq add ${tk} ${work}`;
  handlePre({ session_id: sid2, tool_name: 'Bash', tool_input: { command: cmd }, tool_use_id: 'td', cwd: work });
  const job = '1792999999-123-t2';
  fs.writeFileSync(`${tmp}/dcq/running/${job}.job`, `TASK=${tk}\nCWD=${work}\n`);
  const r = handlePost({ session_id: sid2, hook_event_name: 'PostToolUse', tool_name: 'Bash', tool_input: { command: cmd }, tool_use_id: 'td', tool_response: { stdout: `LINT OK\n${job}\n` } });
  assert.equal(r.kind, 'dispatched');
  const p = G.readLedger(sid2).pending[0];
  assert.equal(p.jobId, job);
  assert.equal(G.runVerify(sid2, p.id).rc, 75, 'running 不算完工');
  fs.renameSync(`${tmp}/dcq/running/${job}.job`, `${tmp}/dcq/done/${job}.job`);
  assert.equal(G.runVerify(sid2, p.id).rc, 0);
  fs.writeFileSync(tk, ticketText('true'));
  assert.equal(G.runVerify(sid2, p.id).rc, 3, '工單驗收被改 → wo-verify --pinned exit 3');
  // dcq add 被拒（沒有 job id）→ launch-failed
  const tk3 = `${tmp}/t3.md`; fs.writeFileSync(tk3, ticketText(GOOD));
  handlePre({ session_id: sid2, tool_name: 'Bash', tool_input: { command: `dcq add ${tk3}` }, tool_use_id: 'tf', cwd: work });
  handlePost({ session_id: sid2, hook_event_name: 'PostToolUse', tool_name: 'Bash', tool_input: {}, tool_use_id: 'tf', tool_response: { stdout: 'dcq: deep-lint 拒收' } });
  assert.equal(G.readLedger(sid2).pending.find((x) => x.toolUseId === 'tf').status, 'launch-failed');
}
// 改派要求要等派出才解除（PostToolUse 確認）
{
  const sid3 = 'sess-clear';
  let a = handlePre({ session_id: sid3, tool_name: 'Bash', tool_input: { command: 'npm test' }, tool_use_id: 'x1', cwd: work });
  assert.equal(a.kind, 'reroute');
  const inA = { subagent_type: 'o-worker', prompt: ticketText(GOOD) };
  handlePre({ session_id: sid3, tool_name: 'Agent', tool_input: inA, tool_use_id: 'x2', cwd: work });
  a = handlePre({ session_id: sid3, tool_name: 'Bash', tool_input: { command: 'npm test' }, tool_use_id: 'x3', cwd: work });
  assert.equal(a.kind, 'reroute', 'PreToolUse 通過不等於派出');
  handlePost({ session_id: sid3, hook_event_name: 'PostToolUse', tool_name: 'Agent', tool_input: inA, tool_use_id: 'x2', tool_response: { status: 'async_launched', agentId: 'q' } });
  a = handlePre({ session_id: sid3, tool_name: 'Bash', tool_input: { command: 'npm test' }, tool_use_id: 'x4', cwd: work });
  assert.notEqual(a?.kind, 'reroute');
  // 重驗指令本身不被改派
  a = handlePre({ session_id: sid3, tool_name: 'Bash', tool_input: { command: G.runnerCmd(sid3, 'zz') }, tool_use_id: 'x5', cwd: work });
  assert.equal(a.kind, 'allow');
}
// 帳本損壞：改名保留、Stop 明報一次
{
  const sid4 = 'sess-bad';
  fs.mkdirSync(path.dirname(G.ledgerFile(sid4)), { recursive: true });
  fs.writeFileSync(G.ledgerFile(sid4), '{half');
  assert.match(G.updateLedger(sid4, (l) => G.stopCheck(l, sid4)), /帳本損壞/);
  assert.equal(G.updateLedger(sid4, (l) => G.stopCheck(l, sid4)), '');
  assert.ok(fs.readdirSync(path.dirname(G.ledgerFile(sid4))).some((f) => f.includes('.corrupt-')));
}
// 並發：8 個行程各加 20 次，不得遺失
{
  const lf = G.ledgerFile('sess-race');
  const script = `import('${path.resolve(path.dirname(new URL(import.meta.url).pathname), '../ledger.mjs')}').then((G)=>{for(let i=0;i<20;i++)G.updateLedger('sess-race',(l)=>{l.n=(l.n??0)+1;});})`;
  await Promise.all(Array.from({ length: 8 }, () => new Promise((res, rej) => {
    const c = spawn('node', ['--input-type=module', '-e', script], { env: process.env, stdio: 'inherit' });
    c.on('exit', (code) => (code === 0 ? res() : rej(new Error(`child ${code}`))));
  })));
  assert.equal(JSON.parse(fs.readFileSync(lf, 'utf8')).n, 160);
}

// —— 端到端：真的跑 hook 程序與 hooks.json 註冊 ——
const dir = path.dirname(new URL(import.meta.url).pathname);
const hook = (file, payload) => execFileSync('node', [path.join(dir, '..', file)], { input: typeof payload === 'string' ? payload : JSON.stringify(payload), env: process.env }).toString();
{
  fs.writeFileSync(`${tmp}/cascade.json`, JSON.stringify({ delegate: 'http://127.0.0.1:9' }));
  assert.equal(hook('prompt.mjs', { session_id: 'e1', prompt: '每個檔都看一下' }), '', 'Laya 不通 → 放行');
  const out = JSON.parse(hook('delegate-guard.mjs', { session_id: 'e1', tool_name: 'Agent', tool_input: { subagent_type: 'o-worker', prompt: '去做' }, tool_use_id: 'e', cwd: work }));
  assert.match(out.hookSpecificOutput.permissionDecisionReason, /驗收閘/);
  assert.equal(hook('delegate-guard.mjs', { session_id: 'e1', agent_id: 'sub', tool_name: 'Bash', tool_input: { command: 'npm test' } }), '', '子代理內不計');
  assert.equal(hook('delegate-guard.mjs', '{not json'), '');
  const blocked = JSON.parse(hook('stop.mjs', { session_id: 'sess-life' }) || '{}');
  assert.equal(blocked.decision, 'block', 'C、D 完工未重驗 → 擋');
  assert.match(blocked.reason, /還沒重驗/);
  assert.equal(hook('subagent-stop.mjs', { session_id: 'e1', agent_type: 'o-worker', agent_id: 'zz' }), '');
  assert.deepEqual(G.readLedger('e1').orphanStops, ['zz']);
  fs.writeFileSync(`${tmp}/off`, '');
  assert.equal(hook('delegate-guard.mjs', { session_id: 'e2', tool_name: 'Bash', tool_input: { command: 'npm test' } }), '', '/deguard off');
  fs.rmSync(`${tmp}/off`);
  const hj = JSON.parse(fs.readFileSync(path.join(dir, '../hooks.json'), 'utf8')).hooks;
  for (const [ev, file] of [['UserPromptSubmit', 'prompt.mjs'], ['PreToolUse', 'delegate-guard.mjs'], ['PostToolUse', 'post-tool.mjs'], ['PostToolUseFailure', 'post-tool.mjs'], ['SubagentStop', 'subagent-stop.mjs'], ['Stop', 'stop.mjs']]) {
    assert.ok(JSON.stringify(hj[ev] ?? '').includes(`hooks/${file}`), `hooks.json 缺 ${ev} → ${file}`);
    assert.ok(fs.existsSync(path.join(dir, '..', file)));
  }
}

// —— invalidate：派工指令不把 shell cwd 當寫入位置（11-07 dmw5zode436ba）——
{
  const chain = 'openmausbot run Builder --message-file /Users/you/OpenBot/Shared/a.md > /tmp/b.log 2>&1; deep-run /tmp/a.md /Users/you/dev/vibe-shorts-pipeline; openmausbot run Builder --wait';
  assert.ok(chain.split('; ').every(isDispatchedCmd), '派工指令都認得');
  assert.deepEqual(L.dispatchTargets('deep-run /tmp/a.md /Users/you/dev/vibe-shorts-pipeline'), ['/Users/you/dev/vibe-shorts-pipeline']);
  const mk = () => ({ pending: [{ id: 'x', cwd: '/Users/you/OpenBot/omb', verified: { rc: 0 }, stale: false }] });
  const r = (c) => G.invalidate(mk(), { tool: 'Bash', input: { command: c }, cwd: '/Users/you/OpenBot/omb' });
  assert.equal(r('openmausbot run Builder --message-file /Users/you/OpenBot/Shared/a.md > /tmp/b.log 2>&1'), 0);
  assert.equal(r('dcq add /tmp/t.md /Users/you/dev/vibe-shorts-pipeline'), 0);
  assert.equal(r('deep-run /Users/you/OpenBot/Shared/x.md /Users/you/dev/vibe-shorts-pipeline'), 0);
  assert.equal(r('touch egg-send.sh'), 1, '真寫入仍作廢');
  assert.equal(r('deep-run /tmp/a.md /Users/you/OpenBot/omb'), 1, 'deep 的 cwd 就是 pending.cwd');
  assert.equal(r('deep-run /tmp/a.md /Users/you/dev/vibe-shorts-pipeline; rm egg-send.sh'), 1, '混其他寫入段維持保守');
}
fs.rmSync(tmp, { recursive: true });
console.log('ALL PASS');
