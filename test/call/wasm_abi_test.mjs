import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createWasmHost, instantiateWasm } from './synurang_wasm.js';
import { CallsClient } from './conformance_ffi.js';
import { createNativeHost } from './synurang_node.js';
import { Value } from './conformance_lite.js';
for (const provider of ['c', 'cpp', 'rust']) {
  const bytes = await readFile(new URL(`./${provider}_module.wasm`, import.meta.url));
  const compiled = await WebAssembly.compile(bytes);
  assert.deepEqual(WebAssembly.Module.imports(compiled), [{ module: 'synurang', name: 'wakeup', kind: 'function' }], `${provider} notification import`);
  const module = await instantiateWasm(bytes);
  const host = await createWasmHost(() => module, { capacity: 1 });
  try {
    const client = new CallsClient(host);
    assert.equal((await client.unary(new Value({ value: 1 }))).value, 1);
    const previous = module.memory.buffer;
    module.memory.grow(1);
    assert.notEqual(module.memory.buffer, previous);
    assert.equal((await client.unary(new Value({ value: 2 }))).value, 2);
  } finally { await host.close(); }
}
// Scheduling after teardown must not touch the unloaded table or instance.
const closed = await createNativeHost(new URL('./c_module.so', import.meta.url).pathname);
await closed.close();
await closed.turn();
console.log('Notification ABI, standard WASM and memory growth conformance passed');
