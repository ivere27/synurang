import { observeModule } from './polling_contract.mjs';
import { serveWorker } from './synurang_worker.js';
import { createWasmHost, instantiateWasm } from './synurang_wasm.js';

const node = !!globalThis.process?.versions?.node;
const port = node ? (await import('node:worker_threads')).parentPort : self;
serveWorker(port, async () => {
  const url = new URL('./c_module.wasm', import.meta.url);
  const bytes = node ? await (await import('node:fs/promises')).readFile(url)
    : await (await fetch(url)).arrayBuffer();
  const module = observeModule(await instantiateWasm(bytes), snapshot =>
    port.postMessage({ pollingObservation: 1, snapshot }));
  return createWasmHost(() => module, { capacity: 2 });
});
