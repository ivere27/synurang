import { CallsClient } from './conformance_ffi.js';
import { Value } from './conformance_lite.js';
import { type Transport } from './synurang_runtime.js';
export type TestHost = Transport & { close(): Promise<void> };
function equal(actual: unknown, expected: unknown): void {
  if (actual !== expected) throw new Error(`Expected ${expected}, got ${actual}`);
}
async function fails(promise: Promise<unknown>, code: number): Promise<void> {
  try { await promise; } catch (error) {
    equal((error as { code: number }).code, code);
    return;
  }
  throw new Error(`Expected RPC status ${code}`);
}
const value = (number: number) => new Value({ value: number });
export async function conformance(create: () => Promise<TestHost> | TestHost): Promise<void> {
  const host = await create(), second = await create();
  const client = new CallsClient(host), other = new CallsClient(second);
  try {
    equal((await client.unary(value(0))).value, 0);
    equal((await client.unary(value(42))).value, 42);
    let count = 0;
    for await (const response of client.server(value(50))) equal(response.value, count++);
    equal(count, 50);
    equal((await client.client(Array.from({ length: 50 }, (_, n) => value(n)))).value, 1225);
    equal((await client.client([value(-2), ...Array.from({ length: 100 }, () => value(1))])).value, 42);
    let firstInput = true, returned = false;
    const suspended: AsyncIterable<Value> = {
      [Symbol.asyncIterator]() { return {
        next() {
          if (firstInput) { firstInput = false; return Promise.resolve({ done: false as const, value: value(-2) }); }
          return new Promise<IteratorResult<Value>>(() => {});
        },
        return() { returned = true; return Promise.resolve({ done: true as const, value: undefined }); },
      }; },
    };
    equal((await client.client(suspended, { timeoutMs: 1000 })).value, 42);
    equal(returned, true);
    const closedInput = await host.open({ path: '/synurang.test.Calls/Server', requestStream: false, responseStream: true });
    try {
      await closedInput.send(value(100).toBinary());
      await closedInput.halfClose();
      try { await closedInput.send(new Uint8Array()); throw new Error('Write after half-close succeeded'); }
      catch (error) { equal((error as Error).name, 'RequestClosedError'); }
      let received = 0;
      for (;;) {
        const bytes = await closedInput.recv();
        if (bytes === null) break;
        equal(Value.fromBinary(bytes).value, received++);
      }
      equal(received, 100);
    } finally { await closedInput.close(); }
    const bidi = await client.bidi();
    try {
      for (let n = 0; n < 30; ++n) {
        await bidi.send(value(n));
        // An adapter that buffers until halfClose deadlocks on this receive.
        equal((await bidi.recv())?.value, n);
      }
      await bidi.halfClose();
      equal(await bidi.recv(), null);
    } finally { await bidi.close(); }
    const concurrent = await client.bidi();
    try {
      await Promise.all([
        (async () => {
          for (let n = 0; n < 500; ++n) await concurrent.send(value(n));
          await concurrent.halfClose();
        })(),
        (async () => {
          let received = 0;
          for await (const response of concurrent.responses) equal(response.value, received++);
          equal(received, 500);
        })(),
      ]);
    } finally { await concurrent.close(); }
    const responses = await Promise.all(Array.from({ length: 25 }, (_, n) => client.unary(value(n))));
    responses.forEach((response, n) => equal(response.value, n));
    equal((await other.unary(value(123))).value, 123);
    await fails(client.fail(value(0)), 7);
    await fails(client.unary(value(-1)), 7);
    const unknown = await host.open({ path: '/unknown.Service/Method', requestStream: false, responseStream: false });
    try { await fails(unknown.send(new Uint8Array()), 12); await fails(unknown.recv(), 12); } finally { await unknown.close(); }
    const abort = new AbortController();
    const waiting = client.wait(value(0), { signal: abort.signal });
    setTimeout(() => abort.abort(), 10);
    await fails(waiting, 1);
    await fails(client.wait(value(0), { timeoutMs: 20 }), 4);
    await fails(client.wait(value(0), { timeoutMs: 0 }), 4);
    await fails(client.wait(value(0), { signal: abort.signal }), 1);
    // Early iterator return cancels and releases its producer.
    for await (const response of client.server(value(10000))) { equal(response.value, 0); break; }
    const pending = client.wait(value(0));
    const rejected = fails(pending, 1);
    await new Promise(resolve => setTimeout(resolve, 5));
    await host.close();
    await rejected;
    await fails(client.unary(value(0)), 14);
    equal((await other.unary(value(9))).value, 9);
  } finally { await host.close(); await second.close(); }
}
