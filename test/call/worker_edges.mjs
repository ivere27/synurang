import assert from 'node:assert/strict';
import { Worker } from 'node:worker_threads';
import { WorkerHost } from './synurang_worker.js';
import { RequestClosedError } from './synurang_runtime.js';

function worker(source) { return new Worker(new URL('data:text/javascript,' + encodeURIComponent(source))); }
const blockingSource = `
  import { parentPort } from 'node:worker_threads';
  const block = () => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1000);
  parentPort.on('message', message => {
    if ((message.op === 'open' && message.method.path === '/slow/Open') || message.op === 'recv') block();
    parentPort.postMessage({synurang:1,id:message.id,value:message.op === 'recv' ? null : undefined});
  });
`;
const method = { path: '/wait/Wait', requestStream: false, responseStream: false };
async function promptly(promise, code) {
  const started = performance.now();
  await assert.rejects(promise, error => error.code === code);
  assert.ok(performance.now() - started < 600, 'Local cancellation waited for the blocked worker');
}

// A worker can be in long synchronous producer work. Parent-side cancellation
// must finish the caller promptly while host close still awaits remote cleanup.
for (const kind of ['deadline', 'abort', 'close']) {
  const host = new WorkerHost(worker(blockingSource));
  try {
    const abort = new AbortController();
    const warmup = await host.open(method);
    await warmup.close();
    const call = await host.open(method, kind === 'deadline' ? { timeoutMs: 150 } : { signal: abort.signal });
    const response = call.recv();
    if (kind === 'abort') setTimeout(() => abort.abort(), 50);
    if (kind === 'close') setTimeout(() => { void call.close(); }, 50);
    await promptly(response, kind === 'deadline' ? 4 : 1);
    const started = performance.now();
    await call.close();
    assert.ok(performance.now() - started < 100, 'Call close waited for remote retirement');
  } finally { await host.close(); }
}
{
  const host = new WorkerHost(worker(blockingSource));
  try {
    await promptly(host.open({ ...method, path: '/slow/Open' }, { timeoutMs: 50 }), 4);
  } finally { await host.close(); }
}

// Request-side EOF is not a terminal RPC error. Preserve its class across
// message ports so a client-streaming caller can still collect its response.
{
  const source = `
    import {parentPort} from 'node:worker_threads';
    import {serveWorker} from ${JSON.stringify(new URL('./synurang_worker.js', import.meta.url).href)};
    import {RequestClosedError} from ${JSON.stringify(new URL('./synurang_runtime.js', import.meta.url).href)};
    serveWorker(parentPort, () => ({
      open: async () => {
        let sent=false, received=false;
        return {
          async send() { if(sent) throw new RequestClosedError(); sent=true; },
          async halfClose() {},
          async recv() { if(received)return null;received=true;return new Uint8Array([8,42]); },
          cancel() {}, async close() {},
        };
      }, async close() {},
    }));
  `;
  const host = new WorkerHost(worker(source));
  try {
    const call = await host.open({ ...method, requestStream: true });
    await call.send(new Uint8Array([8, 1]));
    await assert.rejects(call.send(new Uint8Array([8, 2])), error => error instanceof RequestClosedError);
    assert.deepEqual(await call.recv(), new Uint8Array([8, 42]));
    assert.equal(await call.recv(), null);
    await call.close();
  } finally { await host.close(); }
}
console.log('Worker local cancellation, retirement and request-side EOF regressions passed');
