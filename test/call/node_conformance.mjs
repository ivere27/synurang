import { conformance } from './conformance.js';
import { grpcConformance } from './grpc_conformance.mjs';
import { createWasmHost, instantiateWasm } from './synurang_wasm.js';
import { createNativeHost } from './synurang_node.js';
import { createGoWasmHost } from './synurang_go.js';
import './wasm_exec.js';
import { WorkerHost } from './synurang_worker.js';
import { createLinkedHost } from './synurang_runtime.js';
import { createRequire } from 'node:module';
import { Worker } from 'node:worker_threads';
import { readFile } from 'node:fs/promises';
const require = createRequire(import.meta.url);

for (const [name, create] of [
  ['C native', () => createNativeHost(new URL('./c_module.so', import.meta.url).pathname, { capacity: 2 })],
  ['C WASM', () => createWasmHost(async () => instantiateWasm(await readFile(new URL('./c_module.wasm', import.meta.url))), { capacity: 2 })],
  ['C++ native', () => createNativeHost(new URL('./cpp_module.so', import.meta.url).pathname, { capacity: 2 })],
  ['C++ WASM', () => createWasmHost(async () => instantiateWasm(await readFile(new URL('./cpp_module.wasm', import.meta.url))), { capacity: 2 })],
  ['Rust native', () => createNativeHost(new URL('./rust_module.so', import.meta.url).pathname, { capacity: 2 })],
  ['Rust WASM', () => createWasmHost(async () => instantiateWasm(await readFile(new URL('./rust_module.wasm', import.meta.url))), { capacity: 2 })],
  ['Go native', () => createNativeHost(new URL('./go_module.so', import.meta.url).pathname, { capacity: 2 })],
  ['Go WASM', async () => createGoWasmHost(await readFile(new URL('./go_module.wasm', import.meta.url)), globalThis.Go, { capacity: 2 })],
  ...['c', 'rust', 'go'].map(provider => [provider + ' static addon', () =>
    createLinkedHost(require(`./${provider}_module.node`), { capacity: 2 })]),
  ...['c', 'cpp', 'rust', 'go', 'native-c', 'native-cpp', 'native-rust', 'native-go'].map(provider => [
    provider + ' Node worker', () => new WorkerHost(new Worker(new URL(`./worker.mjs?provider=${provider}`, import.meta.url))),
  ]),
]) {
  await conformance(create);
  await grpcConformance(create);
  console.log(name + ' conformance passed');
}
