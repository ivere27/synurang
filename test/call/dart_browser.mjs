import { chromium } from 'playwright';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve, extname } from 'node:path';
const root = fileURLToPath(new URL('.', import.meta.url));
const server = createServer(async (request, response) => {
  try {
    const path = resolve(root, '.' + new URL(request.url, 'http://localhost').pathname);
    if (!path.startsWith(root)) throw new Error('Invalid path');
    response.setHeader('Content-Type', ({ '.wasm': 'application/wasm', '.js': 'text/javascript', '.mjs': 'text/javascript', '.html': 'text/html' })[extname(path)] ?? 'application/octet-stream');
    response.end(await readFile(path));
  } catch { response.writeHead(404); response.end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const browser = await chromium.launch({ headless: true });
try {
  for (const target of ['js', 'wasm']) {
    const page = await browser.newPage();
    page.on('pageerror', error => console.error(error));
    await page.goto(`http://127.0.0.1:${server.address().port}/dart_browser.html?target=${target}`);
    await page.waitForFunction(() => window.dartResult?.done, undefined, { timeout: 60000 });
    const result = await page.evaluate(() => window.dartResult);
    for (const name of result.passed) console.log(`${name} (${target} compilation) conformance passed`);
    if (result.error) throw new Error(result.error);
    await page.close();
  }
} finally { await browser.close(); server.close(); }
