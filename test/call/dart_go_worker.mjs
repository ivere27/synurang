import './wasm_exec.js';
import { serveWorker } from './synurang_worker.js';
import { createGoWasmHost } from './synurang_go.js';
serveWorker(self, async () => {
  const bytes = await (await fetch(new URL('./go_module.wasm', import.meta.url))).arrayBuffer();
  return createGoWasmHost(bytes, globalThis.Go, { capacity: 2 });
});
