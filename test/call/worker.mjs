import { serveWorker } from './synurang_worker.js';
import { createWasmHost, instantiateWasm } from './synurang_wasm.js';
import { createGoWasmHost } from './synurang_go.js';
const provider = new URL(import.meta.url).searchParams.get('provider') ?? 'c';
const node = !!globalThis.process?.versions?.node;
const port = node ? (await import('node:worker_threads')).parentPort : self;
serveWorker(port, async () => {
  if (['c', 'cpp', 'rust'].includes(provider)) {
    const url = new URL(`./${provider}_module.wasm`, import.meta.url);
    const bytes = node ? await (await import('node:fs/promises')).readFile(url) : await (await fetch(url)).arrayBuffer();
    return createWasmHost(() => instantiateWasm(bytes), { capacity: 2 });
  }
  if (provider === 'go') {
    await import('./wasm_exec.js');
    const url = new URL('./go_module.wasm', import.meta.url);
    const bytes = node ? await (await import('node:fs/promises')).readFile(url) : await (await fetch(url)).arrayBuffer();
    return createGoWasmHost(bytes, globalThis.Go, { capacity: 2 });
  }
  const { createNativeHost } = await import('./synurang_node.js');
  return createNativeHost(new URL(`./${provider.slice(7)}_module.so`, import.meta.url).pathname, { capacity: 2 });
});
