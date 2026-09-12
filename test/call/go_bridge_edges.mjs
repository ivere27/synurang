import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { Host, unary, serverStream } from './synurang_runtime.js';
import { createGoWasmHost } from './synurang_go.js';
import './wasm_exec.js';

const method = { path: '/synurang.test.Calls/Unary', requestStream: false, responseStream: false };
const codec = { encode: value => value, decode: value => value };
const request = Uint8Array.of(8, 42);
const message = { kind: 'message', data: request };
const finished = { kind: 'finished', code: 0, data: new Uint8Array() };

for (const duringEncoding of [false, true]) {
  const abort = new AbortController();
  let encoded = false;
  const host = new Host({
    setWakeup() {},
    openWithRequest() { throw new Error('Cancelled request reached the provider'); },
    destroy() { return 0; },
  });
  const input = { encode() { encoded = true; abort.abort(); return request; } };
  if (!duringEncoding) abort.abort();
  try {
    await assert.rejects(unary(host, method, request, input, codec, { signal: abort.signal }), { code: 1 });
    assert.equal(encoded, duringEncoding);
  } finally { await host.close(); }
}

// The optional batched entry must retain the ordinary helper's error and
// lifetime behavior, including failures after a response has been published.
for (const test of [
  { name: 'success', status: 0, results: [message, finished] },
  { name: 'initial backpressure', status: -4, results: [message, finished] },
  { name: 'missing response', status: 0, results: [finished], code: 13 },
  { name: 'extra response', status: 0, results: [message, message, finished], code: 13 },
  { name: 'terminal error', status: 0, results: [message, { ...finished, code: 7 }], code: 7 },
  { name: 'rejected initial write', status: -3, results: [{ ...finished, code: 12 }], code: 12 },
  { name: 'response before rejected write', status: -3, results: [message, finished], error: 'RequestClosedError' },
  { name: 'immediate deadline', status: -3, results: [{ ...finished, code: 4 }], options: { timeoutMs: 0 }, code: 4 },
]) {
  const results = [...test.results];
  let released = 0, opened = 0, sent = 0, halfClosed = 0;
  const host = new Host({
    setWakeup() {},
    open() { throw new Error('Expected batched request'); },
    openWithRequest(actualMethod, data) {
      assert.equal(actualMethod, method);
      assert.deepEqual(data, request);
      opened++;
      return { call: 1n, status: test.status };
    },
    send(_call, data) { sent++; assert.deepEqual(data, request); return 0; },
    halfClose() { halfClosed++; return 0; },
    receive() { return results.shift() ?? { kind: 'pending' }; },
    cancel() {},
    release() { released++; },
    poll() {},
    hasWork() { return false; },
    destroy() { return 0; },
  });
  try {
    const response = unary(host, method, request, codec, codec, test.options);
    if (test.code !== undefined || test.error) {
      await assert.rejects(response, error => test.error ? error.name === test.error : error.code === test.code, test.name);
    } else assert.deepEqual(await response, request, test.name);
    assert.equal(opened, 1, test.name);
    assert.equal(released, 1, test.name);
    assert.equal(sent, test.status === -4 ? 1 : 0, test.name);
    assert.equal(halfClosed, test.status === -4 ? 1 : 0, test.name);
  } finally { await host.close(); }
}

const watchdog = setTimeout(() => { throw new Error('Go bridge edge tests timed out'); }, 15000);
const host = await createGoWasmHost(await readFile(new URL('./go_module.wasm', import.meta.url)), globalThis.Go, { capacity: 1 });
try {
  // Zero-byte protobuf messages are distinct from a pending read or EOF.
  assert.deepEqual(await unary(host, method, new Uint8Array(), codec, codec), new Uint8Array());
  await assert.rejects(unary(host, { ...method, path: '/missing' }, request, codec, codec), { code: 12 });
  await assert.rejects(unary(host, { ...method, requestStream: true }, request, codec, codec), { code: 3 });
  const aborted = new AbortController();
  aborted.abort();
  await assert.rejects(unary(host, method, request, codec, codec, { signal: aborted.signal }), { code: 1 });
  await assert.rejects(unary(host, method, request, codec, codec, { timeoutMs: 0 }), { code: 4 });

  // A large unknown protobuf field is echoed by Go's protobuf implementation.
  // Returned packet views must survive later calls and independent results.
  const large = new Uint8Array(128 * 1024 + 6);
  large.set([8, 42, 18, 0x80, 0x80, 0x08]);
  large.fill(0xa5, 6);
  const first = await unary(host, method, large, codec, codec);
  const second = await unary(host, method, large, codec, codec);
  assert.deepEqual(first, large);
  second.fill(0);
  assert.deepEqual(first, large);

  // A cached terminal must not override the host's local cancellation policy.
  const call = await host.open(method);
  try {
    await call.send(request);
    await call.halfClose();
    assert.deepEqual(await call.recv(), request);
    call.cancel();
    await assert.rejects(call.recv(), { code: 1 });
  } finally { await call.close(); }

  const streaming = { ...method, path: '/synurang.test.Calls/Server', responseStream: true };
  let count = 0;
  for await (const data of serverStream(host, streaming, Uint8Array.of(8, 50), codec, codec)) {
    assert.deepEqual(data, count === 0 ? new Uint8Array() : Uint8Array.of(8, count));
    count++;
  }
  assert.equal(count, 50);
  assert.deepEqual(await unary(host, method, request, codec, codec), request);
} finally {
  await host.close();
  clearTimeout(watchdog);
}
console.log('Go batched requests, result ownership, errors and cancellation passed');
