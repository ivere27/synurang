import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { Worker } from 'node:worker_threads';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { directPolling, workerPolling } from './polling_contract.mjs';
import { pollingFaults } from './polling_faults.mjs';
import { idlePromotion } from './polling_promotion.mjs';

const watchdog = setTimeout(() => { throw new Error('Polling conformance timed out'); }, 20000);
try {
  await directPolling(await readFile(new URL('./c_module.wasm', import.meta.url)));
  console.log('C WASM independent polling passed');
  await workerPolling(Worker);
  console.log('C WASM Node worker independent polling passed');

  await pollingFaults();
  console.log('Background polling failure cleanup passed');
  await idlePromotion();
  await promisify(execFile)(process.execPath,
    [fileURLToPath(new URL('./polling_port_exit.mjs', import.meta.url))], { timeout: 3000 });
  console.log('Idle polling promotion and Node port cleanup passed');

  const server = createServer(async (request, response) => {
    const path = new URL(request.url, 'http://localhost').pathname;
    if (path === '/') {
      response.setHeader('content-type', 'text/html');
      response.end('<!doctype html><title>WASM polling conformance</title>');
      return;
    }
    if (!/^\/[a-zA-Z0-9_.-]+$/.test(path)) { response.writeHead(404).end(); return; }
    try {
      const data = await readFile(new URL(`.${path}`, import.meta.url));
      response.setHeader('content-type', path.endsWith('.wasm') ? 'application/wasm' : 'text/javascript');
      response.end(data);
    } catch { response.writeHead(404).end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  let browser;
  try {
    browser = await chromium.launch({ headless: true });
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(`http://127.0.0.1:${server.address().port}/`);
    await page.evaluate(async () => {
      const { directPolling, workerPolling } = await import('./polling_contract.mjs');
      const { idlePromotion } = await import('./polling_promotion.mjs');
      await directPolling(await (await fetch('./c_module.wasm')).arrayBuffer());
      await workerPolling(Worker);
      await idlePromotion();
    });
    assert.deepEqual(errors, []);
    console.log('C WASM browser and Web Worker independent polling passed');
  } finally {
    await browser?.close();
    await new Promise(resolve => server.close(resolve));
  }
} finally { clearTimeout(watchdog); }
