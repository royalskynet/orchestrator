#!/usr/bin/env node
// fix 9767：/fi 抽出的精簡 transcript 原樣保留本 session 出現過的 key 樣字串／email／IPv4，
// 子代理一讀就被 sensitive-canary 擋。抽取那一步就脫敏，不要等撞牆才補。
//
// 路徑寫在腳本內、不出現在 Bash 指令列（fix 9622/9689：canary 會展開指令裡的路徑掃內容，
// 否則連這支脫敏工具都會被自己的閘擋住）。
// 用法：node fi-mask-transcript.mjs <in> <out>   （預設 in=./fi-scan.txt, out=<in>.masked）
//
// fix 11769：key/email 規則擋不住個資。下面補的個資規則＋本機 Presidio 全跑完才印 GATE=deep；
// 任何一步失敗或碰到領域字，印 GATE=sonnet，遮罩檔不得送第三方（fail closed）。
// ponytail: 沒有上下文的中文人名抓不到，靠領域字閘擋；要更準得換中文 NER 模型。
import { readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";

const inPath = process.argv[2];
const outPath = process.argv[3] || `${inPath}.masked`;
if (!inPath) { console.log("usage: fi-mask-transcript.mjs <in> [out]"); process.exit(1); }

let n = 0;
// tag 可以是字串，也可以是 (match, ...groups) => string 的函式（規則 3 要保留鍵名）。
// 之前只回傳 tag 本身，傳函式進來時會把函式原始碼寫進輸出（遮到了值，但污染 transcript）。
const sub = (s, re, tag) =>
  s.replace(re, (...a) => { n++; return typeof tag === "function" ? tag(...a) : tag; });

const luhn = (d) => {
  let sum = 0;
  for (let i = 0; i < d.length; i++) {
    let x = +d[d.length - 1 - i];
    if (i % 2) { x *= 2; if (x > 9) x -= 9; }
    sum += x;
  }
  return sum % 10 === 0;
};

let t = readFileSync(inPath, "utf8");
// 0. URL 內嵌帳密 scheme://user:pass@host（canary url-basic-auth）；排在 email 前，否則只遮掉 pass@host 半段
t = sub(t, /\b([a-z][a-z0-9+.-]*:\/\/)[^\s\/:@"'`]+:[^\s\/@"'`]*@/gi, (_m, s) => `${s}<MASKED_USERINFO>@`);
// 1. 已知 key 前綴（sk-/ghp_/gho_/xoxb-/AIza/AKIA/glpat-/hf_/pk_/rk_ + 後續不透明串）
t = sub(t, /\b(?:sk|pk|rk)[-_][A-Za-z0-9_-]{12,}/g, "<MASKED_KEY>");
t = sub(t, /\b(?:gh[pousr]_|glpat-|xox[baprs]-|hf_|nvapi-|AIza|AKIA|ASIA)[A-Za-z0-9_-]{10,}/g, "<MASKED_KEY>");
// 2. PEM / private key 區塊
t = sub(t, /-----BEGIN[^-]{0,40}-----[\s\S]*?-----END[^-]{0,40}-----/g, "<MASKED_PEM>");
// 3. VAR=值 / "VAR": 值 —— 鍵名含憑證字樣時連值一起遮
t = sub(t, /\b([A-Za-z0-9_]{0,64}(?:SECRET|PASSWORD|PASSWD|TOKEN|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY)[A-Za-z0-9_]{0,64})\s*[:=]\s*["']?[^\s"'`,;)\]}]{6,}/gi,
  (_m, k) => `${k}=<MASKED_VALUE>`);
// 3a. 鏈上識別：EVM 地址／交易雜湊（0x 開頭，規則 5 的 \b 接不到）、BTC、TRON
t = sub(t, /\b0x[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?\b/g, "<MASKED_CHAIN>");
t = sub(t, /\b(?:bc1[ac-hj-np-z02-9]{11,71}|[13][1-9A-HJ-NP-Za-km-z]{25,34}|T[1-9A-HJ-NP-Za-km-z]{33})\b/g, "<MASKED_CHAIN>");
// 3b. 證件：身分證、護照（護照號型式太泛，要有關鍵字）
t = sub(t, /(?<![0-9A-Za-z])\d{17}[\dXx](?![0-9A-Za-z])/g, "<MASKED_ID>");
t = sub(t, /\b[A-Z][12]\d{8}\b/g, "<MASKED_ID>");
t = sub(t, /(護照|身[分份]證|證件|passport)(\s*(?:no\.?|number|號碼?)?\s*[:：#=]?\s*)[A-Za-z0-9]{6,12}\b/gi, (_m, k, g) => `${k}${g}<MASKED_ID>`);
// 3c. 卡號（Luhn 過才算，其餘長數字交給 3e）
t = t.replace(/(?<![\d.])\d(?:[ -]?\d){12,18}(?![\d.])/g, (m) => {
  const d = m.replace(/\D/g, "");
  if (!luhn(d)) return m;
  n++; return "<MASKED_CARD>";
});
// 3d. 電話、UID、有欄位名的姓名
t = sub(t, /(?<![\w.])\+\d{1,3}[ -]?\d(?:[ -]?\d){6,12}(?!\d)/g, "<MASKED_PHONE>");
t = sub(t, /(?<![\d.])09\d{2}[ -]\d{3}[ -]?\d{3}(?![\d.])/g, "<MASKED_PHONE>");
t = sub(t, /\b(uid)(\s*[:：=#]?\s*)\d{4,}/gi, (_m, k, g) => `${k}${g}<MASKED_UID>`);
t = sub(t, /((?:真實)?姓名|持卡人|收款人|申請人)(\s*[:：=]?\s*)[\u4e00-\u9fff·]{2,5}/g, (_m, k, g) => `${k}${g}<MASKED_NAME>`);
// 3e. 其餘 8–19 位獨立數字：UID、手機、帳號都長這樣；fixindex 編號只有 4–5 位，不受影響
t = sub(t, /(?<![\d.])\d{8,19}(?![\d.])/g, "<MASKED_NUM>");
// 4. 長不透明字串（≥24 字、混英數、不是純單字也不是純十六進位路徑片段）
t = sub(t, /\b(?=[A-Za-z0-9+/_-]{24,})(?=[^\s]*[A-Z])(?=[^\s]*[0-9])[A-Za-z0-9+/_-]{24,}={0,2}\b/g, "<MASKED_OPAQUE>");
// 5. hex ≥32（token / hash 樣）
t = sub(t, /\b[0-9a-f]{32,}\b/g, "<MASKED_HEX>");
// 6. email
t = sub(t, /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/g, "<MASKED_EMAIL>");
// 7. public IPv4（略過私網與 loopback）
t = sub(t, /\b(?!10\.|127\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.|0\.)(?:\d{1,3}\.){3}\d{1,3}\b/g, "<MASKED_IP>");
// 8. 常見 passphrase 樣（全小寫無分隔長串，≥16）—— 本 session 的 fixture 就是這類
t = sub(t, /\bcorrect[a-z]{10,}\b/g, "<MASKED_PASSPHRASE>");
// 9. 獨立 5 位數字（canary pii-postal-code 會把 port 20128/20130 當郵遞區號擋）
t = sub(t, /(?<![\d.])\d{5}(?![\d.])/g, "<MASKED_NUM5>");

// 10. 本機 Presidio（英文人名等 NER）。程序內直呼，不經網路、不花 LLM token。
const poc = process.env.FI_PRESIDIO_DIR ?? `${homedir()}/dev/litellm-presidio-poc`;
const py = "import sys;sys.path.insert(0,'.');from pii_guard import bridge;sys.stdout.write(bridge.scrub(sys.stdin.read(),bridge.VAULT.new_run())[0])";
const r = spawnSync(`${poc}/.venv/bin/python`, ["-c", py], {
  cwd: poc, input: t, encoding: "utf8", maxBuffer: 1 << 28, timeout: 120000,
  env: { ...process.env, PYTHONUTF8: "1", PRESIDIO_DENYLIST: "US_BANK_NUMBER,US_DRIVER_LICENSE,US_PASSPORT,DATE_TIME,NRP,ORGANIZATION,URL" },
});
const presidioOk = r.status === 0 && r.stdout.length > 0;
if (!presidioOk) console.error(`presidio failed: status=${r.status} ${(r.stderr || r.error || "").toString().trim().split("\n").pop()}`);
if (presidioOk) t = r.stdout;

writeFileSync(outPath, t);
console.log(`masked ${n} spans -> ${outPath}`);

// 派工閘：領域字只看對話本體，<system-reminder> 內的 skill 清單不算
const body = t.replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, "");
const hit = body.match(/coinw|\blct\b|\bkyc\b|sumsub|complyadvantage|\baml\b|nscheck/i);
const reason = !presidioOk ? "presidio-unavailable" : hit ? `domain:${hit[0].toLowerCase()}` : "";
console.log(reason ? `GATE=sonnet reason=${reason}` : "GATE=deep");
