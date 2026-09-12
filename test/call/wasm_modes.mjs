import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createWasmHost, instantiateWasm } from './synurang_wasm.js';

const unsupported = /Shared-memory WASM is not supported/;
const utf8 = value => [...new TextEncoder().encode(value)];
const name = value => [utf8(value).length, ...utf8(value)];
// These deliberately tiny sections fit one-byte ULEB lengths. The imported
// initializer proves rejected modules never enter their reactor initializer.
const section = (id, bytes) => [id, bytes.length, ...bytes];
function sharedModule(importedMemory) {
  const imports = [1 + Number(importedMemory), ...name('env'), ...name('initialize'), 0, 0];
  if (importedMemory) imports.push(...name('env'), ...name('memory'), 2, 3, 1, 1);
  return new Uint8Array([
    0, 97, 115, 109, 1, 0, 0, 0,
    ...section(1, [1, 96, 0, 0]),
    ...section(2, imports),
    ...(importedMemory ? [] : section(5, [1, 3, 1, 1])),
    ...section(7, [2, ...name('memory'), 2, 0, ...name('_initialize'), 0, 0]),
  ]);
}

for (const importedMemory of [false, true]) {
  let initialized = false;
  const env = { initialize() { initialized = true; } };
  if (importedMemory) env.memory = new WebAssembly.Memory({ initial: 1, maximum: 1, shared: true });
  await assert.rejects(instantiateWasm(sharedModule(importedMemory), { env }), unsupported);
  assert.equal(initialized, false, 'Unsupported module initializer ran');
}

let allocated = false, created = false;
const shared = {
  memory: new WebAssembly.Memory({ initial: 1, maximum: 1, shared: true }),
  synurang_module_alloc() { allocated = true; return 1; },
  synurang_module_create() { created = true; return 1; },
};
await assert.rejects(createWasmHost(() => shared), unsupported);
assert.equal(allocated, false, 'Unsupported factory allocated host state');
assert.equal(created, false, 'Unsupported factory created an instance');

// The guard also works when the browser does not expose this constructor.
const descriptor = Object.getOwnPropertyDescriptor(globalThis, 'SharedArrayBuffer');
try {
  delete globalThis.SharedArrayBuffer;
  await assert.rejects(createWasmHost(() => shared), unsupported);
} finally { Object.defineProperty(globalThis, 'SharedArrayBuffer', descriptor); }

// A normal fixture uses ordinary ArrayBuffer memory and the loader's wakeup import.
const module = await instantiateWasm(await readFile(new URL('./c_module.wasm', import.meta.url)));
assert.equal(Object.prototype.toString.call(module.memory.buffer), '[object ArrayBuffer]');
const host = await createWasmHost(() => module, { capacity: 1 });
try {
  const call = await host.open({ path: '/synurang.test.Calls/Unary', requestStream: false, responseStream: false });
  try {
    await call.send(new Uint8Array([8, 42]));
    await call.halfClose();
    assert.deepEqual(await call.recv(), new Uint8Array([8, 42]));
    assert.equal(await call.recv(), null);
  } finally { await call.close(); }
} finally { await host.close(); }

console.log('Non-shared WASM execution modes and shared-memory rejection passed');
