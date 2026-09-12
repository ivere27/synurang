import { Host, type Instance, type Method, type ReadResult } from './synurang_runtime.js';

/** Standard, non-shared WebAssembly exports used by Clang C/C++ and Rust.
 * Execution is same-thread polling, directly or inside an independent Worker. */
export interface WasmModule {
  readonly memory: WebAssembly.Memory;
  synurang_module_abi_version(): number;
  synurang_module_create(capacity: number, token: number): number;
  registerWakeup(callback: () => void): number;
  unregisterWakeup(token: number): void;
  synurang_module_destroy(instance: number): number;
  synurang_module_open(instance: number, method: number, requestStream: number,
    responseStream: number, timeoutMs: number): bigint;
  synurang_module_send(instance: number, call: bigint, data: number, size: number): number;
  synurang_module_half_close(instance: number, call: bigint): number;
  synurang_module_receive(instance: number, call: bigint, result: number): number;
  synurang_module_cancel(instance: number, call: bigint, code: number): number;
  synurang_module_release(instance: number, call: bigint): void;
  synurang_module_poll(instance: number, budget: number): number;
  synurang_module_has_work(instance: number): number;
  synurang_module_free(pointer: number): void;
  synurang_module_alloc(size: number): number;
}

function rejectSharedMemory(memory: WebAssembly.Memory): void {
  // Do not depend on the SharedArrayBuffer global: browsers may omit that
  // constructor, and memory objects may originate in another JS realm.
  if (Object.prototype.toString.call(memory.buffer) === '[object SharedArrayBuffer]')
    throw new Error('Shared-memory WASM is not supported. Use same-thread polling or a Worker with its own non-shared instance.');
}

class WasmInstance implements Instance {
  private readonly instance: number;
  private readonly result: number;
  private readonly token: number;
  private wakeup = () => {};
  setWakeup(callback: () => void): void { this.wakeup = callback; }
  constructor(private readonly module: WasmModule, capacity: number) {
    this.result = this.alloc(16);
    this.token = module.registerWakeup(() => this.wakeup());
    this.instance = module.synurang_module_create(capacity, this.token);
    if (!this.instance) {
      module.synurang_module_free(this.result);
      module.unregisterWakeup(this.token);
      throw new Error('WASM module could not create an instance');
    }
  }
  private alloc(size: number): number {
    const pointer = this.module.synurang_module_alloc(size);
    if (!pointer) throw new Error('WASM allocation failed');
    return pointer;
  }
  private bytes<T>(data: Uint8Array, callback: (pointer: number) => T): T {
    const pointer = this.alloc(data.byteLength);
    try {
      new Uint8Array(this.module.memory.buffer).set(data, pointer);
      return callback(pointer);
    } finally { this.module.synurang_module_free(pointer); }
  }
  open(method: Method, timeoutMs?: number): bigint {
    if (method.path.includes('\0')) throw new Error('NUL in method path');
    return this.bytes(new TextEncoder().encode(method.path + '\0'), pointer =>
      this.module.synurang_module_open(this.instance, pointer,
        +method.requestStream, +method.responseStream, timeoutMs ?? -1));
  }
  send(call: bigint, data: Uint8Array): number {
    return this.bytes(data, pointer =>
      this.module.synurang_module_send(this.instance, call, pointer, data.byteLength));
  }
  halfClose(call: bigint): number { return this.module.synurang_module_half_close(this.instance, call); }
  receive(call: bigint): ReadResult {
    const status = this.module.synurang_module_receive(this.instance, call, this.result);
    // Re-read memory.buffer after every WASM call: memory.grow detaches old views.
    const view = new DataView(this.module.memory.buffer);
    const kind = view.getUint32(this.result, true);
    const code = view.getInt32(this.result + 4, true);
    const pointer = view.getUint32(this.result + 8, true);
    const size = view.getUint32(this.result + 12, true);
    try {
      if (status !== 0) throw new Error(`WASM receive failed (${status})`);
      if (kind === 0) return { kind: 'pending' };
      const data = new Uint8Array(this.module.memory.buffer).slice(pointer, pointer + size);
      if (kind === 1) return { kind: 'message', data };
      if (kind === 2) return { kind: 'finished', code, data };
      throw new Error(`Invalid WASM read kind ${kind}`);
    } finally { if (pointer) this.module.synurang_module_free(pointer); }
  }
  cancel(call: bigint, code: number): void { this.module.synurang_module_cancel(this.instance, call, code); }
  release(call: bigint): void { this.module.synurang_module_release(this.instance, call); }
  poll(budget: number): number { return this.module.synurang_module_poll(this.instance, budget); }
  hasWork(): boolean { return !!this.module.synurang_module_has_work(this.instance); }
  destroy(): number {
    const status = this.module.synurang_module_destroy(this.instance);
    if (status === 0) {
      this.module.unregisterWakeup(this.token);
      this.module.synurang_module_free(this.result);
    }
    return status;
  }
}
export async function createWasmHost(
    factory: () => Promise<WasmModule> | WasmModule, options: { capacity?: number } = {}): Promise<Host> {
  const capacity = options.capacity ?? 16;
  if (!Number.isInteger(capacity) || capacity < 1 || capacity > 65536)
    throw new RangeError('capacity must be between 1 and 65536');
  const module = await factory();
  rejectSharedMemory(module.memory);
  return new Host(new WasmInstance(module, capacity));
}

/** Instantiate a standard core WASM module. Imports are explicit: applications
 * using OS services provide their own WASI/custom imports. Synurang itself has
 * only imports the instance notification callback, supplied here. Reactor
 * initialization runs exactly once per instantiation.
 * Shared memory / WASM threads are unsupported; Worker hosts instantiate their
 * own non-shared module and exchange messages instead. */
export async function instantiateWasm(bytes: BufferSource,
    imports: WebAssembly.Imports = {}): Promise<WasmModule> {
  const wakeups = new Map<number, () => void>();
  let token = 0;
  const { instance } = await WebAssembly.instantiate(bytes, {
    ...imports, synurang: { ...imports.synurang, wakeup: (id: number) => wakeups.get(id)?.() },
  });
  const exports = instance.exports;
  if (!(exports.memory instanceof WebAssembly.Memory)) throw new Error('Missing WASM memory export');
  rejectSharedMemory(exports.memory);
  if (typeof exports.synurang_module_abi_version !== 'function' || exports.synurang_module_abi_version() !== 1)
    throw new Error('Unsupported Synurang WASM ABI');
  for (const operation of ['create', 'destroy', 'open', 'send', 'half_close', 'receive',
      'cancel', 'release', 'poll', 'has_work', 'free', 'alloc']) {
    if (typeof exports['synurang_module_' + operation] !== 'function')
      throw new Error('Missing WASM export synurang_module_' + operation);
  }
  if (typeof exports._initialize === 'function') exports._initialize();
  return { ...exports,
    registerWakeup(callback: () => void) { wakeups.set(++token, callback); return token; },
    unregisterWakeup(id: number) { wakeups.delete(id); },
  } as unknown as WasmModule;
}
