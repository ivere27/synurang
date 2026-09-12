/** Node-only loader. Browser applications import synurang_wasm/worker instead. */
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { Host, type Instance } from './synurang_runtime.js';

/** The native adapter uses libuv notifications so producer threads never wait
 * for JavaScript or enter the provider again from a callback. */
export async function createNativeHost(path: string,
    options: { capacity?: number; symbol?: string; addonPath?: string } = {}): Promise<Host> {
  const capacity = options.capacity ?? 16;
  if (!Number.isInteger(capacity) || capacity < 1 || capacity > 65536)
    throw new RangeError('capacity must be between 1 and 65536');
  const addon = createRequire(import.meta.url)(options.addonPath ??
    fileURLToPath(new URL('./synurang_module_host.node', import.meta.url))) as {
      createInstance(capacity: number, path: string, symbol: string): Instance;
    };
  return new Host(addon.createInstance(capacity, path, options.symbol ?? 'Synurang_GetApi'));
}

export { createLinkedHost } from './synurang_runtime.js';
