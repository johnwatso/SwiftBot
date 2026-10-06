#!/usr/bin/env node
//
// Captures the website's Web UI screenshots from the showcase preview.
//
//   SHOWCASE=1 PORT=4180 node Tools/AdminPreview/server.js   (or the admin-showcase launch entry)
//   node Tools/AdminPreview/screenshots.mjs
//
// Drives Playwright's Chrome for Testing over the DevTools protocol (no npm
// packages needed), then writes WebP files into Website/public/assets/landing
// with cwebp. Desktop pages are 1512×945 CSS px at 2×, captured as four
// tiles with a raised GPU memory budget: headless Chrome never finishes a
// single 2× frame of the Recordings page, but quarter-size clips work. Bump screenshotAssetVersion in
// Website/public/assets/js/site.js after regenerating.

import { spawn, execFileSync } from 'node:child_process';
import { writeFileSync, mkdtempSync, readdirSync, existsSync, rmSync } from 'node:fs';
import { tmpdir, homedir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const BASE = process.env.SHOWCASE_URL || 'http://127.0.0.1:4180/';
const OUT = join(dirname(fileURLToPath(import.meta.url)), '../../Website/public/assets/landing');
const PAGES = ['overview', 'recordings', 'rewind', 'gametracker', 'patchy', 'swiftmesh', 'analytics'];
const PHONE_SCRIPT = `(() => {
  document.body.style.paddingTop = '54px';
  const greeting = document.getElementById('homeGreeting');
  if (greeting) greeting.textContent = greeting.textContent.replace(/^Good \\w+/, 'Good morning');
  const date = document.getElementById('homeDate');
  if (date) date.textContent = new Date().toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' }) + ' · 9:41 AM';
})()`;
const SCRIPTS = { recordings: `[...document.querySelectorAll('button')].find(b => b.textContent.trim() === 'Games')?.click()` };

function findChrome() {
  if (process.env.CHROME_BIN) return process.env.CHROME_BIN;
  const cache = join(homedir(), 'Library/Caches/ms-playwright');
  const dir = existsSync(cache) && readdirSync(cache).filter(d => /^chromium-\d+$/.test(d)).sort().pop();
  const bin = dir && join(cache, dir, 'chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
  if (!bin || !existsSync(bin)) throw new Error('Chrome for Testing not found; set CHROME_BIN or run `npx playwright install chromium`.');
  return bin;
}

const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const work = mkdtempSync(join(tmpdir(), 'swiftbot-shots-'));
const port = 9333;
const chrome = spawn(findChrome(), ['--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${join(work, 'profile')}`, '--hide-scrollbars', '--no-first-run',
  // Without the larger GPU budget even the quarter tiles of Recordings stall.
  '--force-gpu-mem-available-mb=4096', '--disable-renderer-backgrounding', '--disable-background-timer-throttling', 'about:blank'], { stdio: 'ignore' });

let wsURL;
for (let i = 0; i < 50 && !wsURL; i++) {
  try { wsURL = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find(t => t.type === 'page')?.webSocketDebuggerUrl; } catch {}
  if (!wsURL) await sleep(200);
}
const ws = new WebSocket(wsURL);
await new Promise(r => ws.addEventListener('open', r, { once: true }));
let nextID = 0;
const pending = new Map();
ws.addEventListener('message', (e) => { const m = JSON.parse(e.data); pending.get(m.id)?.(m); pending.delete(m.id); });
const send = (method, params = {}) => Promise.race([
  new Promise((resolve, reject) => {
    const id = ++nextID;
    pending.set(id, (m) => m.error ? reject(new Error(`${method}: ${m.error.message}`)) : resolve(m.result));
    ws.send(JSON.stringify({ id, method, params }));
  }),
  sleep(30000).then(() => { throw new Error(`${method} timed out`); })
]);
const capture = (params) => send('Page.captureScreenshot', { format: 'png', ...params });

async function load(hash, { width, height, scale, mobile, scheme, script }) {
  // Leaving mobile emulation in place stalls the next navigation, so reset first.
  await send('Emulation.clearDeviceMetricsOverride');
  await send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: scale, mobile });
  await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: scheme }, { name: 'prefers-reduced-motion', value: 'reduce' }] });
  // Chrome for Testing occasionally never answers a navigation; one retry
  // is enough in practice.
  for (let attempt = 1; ; attempt++) {
    try {
      await send('Page.navigate', { url: 'about:blank' });
      await sleep(100);
      await send('Page.navigate', { url: `${BASE}#${hash}` });
      break;
    } catch (error) {
      if (attempt >= 2) throw error;
      console.log(`retrying ${hash}: ${error.message}`);
    }
  }
  await sleep(4000);
  if (script) { await send('Runtime.evaluate', { expression: script }); await sleep(3500); }
}

function saveWebP(name, png) {
  const file = join(work, `${name}.png`);
  writeFileSync(file, png);
  execFileSync('cwebp', ['-quiet', '-q', '82', '-m', '6', file, '-o', join(OUT, `${name}.webp`)]);
  console.log('wrote', `${name}.webp`);
}

try {
  await send('Page.enable');
  await send('Runtime.enable');
  for (const scheme of ['dark', 'light']) {
    for (const page of PAGES) {
      const width = 1512, height = 945;
      await load(page, { width, height, scale: 1, mobile: false, scheme, script: SCRIPTS[page] });
      const tiles = [];
      for (let ty = 0; ty < 2; ty++) for (let tx = 0; tx < 2; tx++) {
        const r = await capture({ clip: { x: tx * width / 2, y: ty * height / 2, width: width / 2, height: height / 2, scale: 2 } });
        const f = join(work, `tile-${ty}${tx}.png`);
        writeFileSync(f, Buffer.from(r.data, 'base64'));
        tiles.push(f);
      }
      const stitched = join(work, `webui-${page}-${scheme}.png`);
      execFileSync('python3', ['-c', [
        'import sys', 'from PIL import Image',
        't = [Image.open(f) for f in sys.argv[2:]]', 'w, h = t[0].size', 'im = Image.new("RGB", (w * 2, h * 2))',
        'for i, x in enumerate(t): im.paste(x, ((i % 2) * w, (i // 2) * h))', 'im.save(sys.argv[1])'
      ].join('\n'), stitched, ...tiles]);
      execFileSync('cwebp', ['-quiet', '-q', '82', '-m', '6', stitched, '-o', join(OUT, `webui-${page}-${scheme}.webp`)]);
      console.log('wrote', `webui-${page}-${scheme}.webp`);
    }
    // iPhone 17 viewport. The site draws the phone frame and a 9:41 status
    // bar over the top 54 pt, so leave that much room (as Safari's safe area
    // would) and make the page's clock agree with the status bar.
    await load('overview', { width: 402, height: 874, scale: 3, mobile: true, scheme, script: PHONE_SCRIPT });
    saveWebP(`webui-phone-${scheme}`, Buffer.from((await capture({})).data, 'base64'));
  }
} finally {
  ws.close();
  // Chrome keeps writing its profile until it exits, so clean up after that.
  await new Promise(r => { chrome.once('exit', r); chrome.kill(); });
  rmSync(work, { recursive: true, force: true, maxRetries: 3 });
}
