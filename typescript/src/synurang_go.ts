import { Host, type Instance, type Method, type ReadResult } from './synurang_runtime.js';

/** Constructor installed by the matching Go toolchain's wasm_exec.js. */
export interface GoRuntime {
  importObject: WebAssembly.Imports;
  env: Record<string, string>;
  run(instance: WebAssembly.Instance): Promise<void>;
}
interface GoInstance {
  open(path: string, requestStream: boolean, responseStream: boolean, timeoutMs: number): string;
  openWithRequest(path: string, requestStream: boolean, responseStream: boolean, timeoutMs: number,
                  data: Uint8Array): [string, number];
  send(call: string, data: Uint8Array): number;
  halfClose(call: string): number;
  receive(call: string): Uint8Array | null;
  cancel(call: string, code: number): void;
  release(call: string): void;
  poll(budget: number): number;
  destroy(): number;
}
interface GoModule { create(capacity: number, wakeup: () => void): GoInstance | null; shutdown(): boolean }

function readPacket(packet: Uint8Array): ReadResult[] {
  const results: ReadResult[] = [];
  const view = new DataView(packet.buffer, packet.byteOffset, packet.byteLength);
  let offset = 0;
  while (offset < packet.byteLength) {
    if (packet.byteLength - offset < 12) throw new Error('Truncated Go read result');
    const kind = view.getUint32(offset, true), code = view.getInt32(offset + 4, true);
    const size = view.getUint32(offset + 8, true);
    offset += 12;
    if (size > packet.byteLength - offset) throw new Error('Truncated Go response');
    // Go gives each packet its own JS buffer; views remain valid across calls.
    const data = packet.subarray(offset, offset + size);
    offset += size;
    if (kind === 1) results.push({ kind: 'message', data });
    else if (kind === 2) results.push({ kind: 'finished', code, data });
    else throw new Error(`Invalid Go read kind ${kind}`);
  }
  if (results.length === 0 || results.length > 2 ||
      (results.length === 2 && (results[0].kind !== 'message' || results[1].kind !== 'finished')))
    throw new Error('Invalid Go read batch');
  return results;
}

/** Go has its own runtime/imports and object bridge; it does not masquerade as
 * a C linear-memory allocator. Calls above this loader use the same Transport.
 * Each host owns its Go runtime, including disposal of its JS callback handles. */
export async function createGoWasmHost(bytes: BufferSource, Go: new () => GoRuntime,
    options: { capacity?: number } = {}): Promise<Host> {
  const capacity = options.capacity ?? 16;
  if (!Number.isInteger(capacity) || capacity < 1 || capacity > 65536)
    throw new RangeError('capacity must be between 1 and 65536');
  const go = new Go();
  const key = '__synurangGoReady_' + crypto.randomUUID().replaceAll('-', '');
  let accept!: (module: GoModule) => void;
  let reject!: (error: unknown) => void;
  const ready = new Promise<GoModule>((resolve, failure) => { accept = resolve; reject = failure; });
  (globalThis as unknown as Record<string, unknown>)[key] = accept;
  go.env = { ...go.env, SYNURANG_READY_CALLBACK: key };
  let running: Promise<void>;
  let module: GoModule;
  try {
    const { instance } = await WebAssembly.instantiate(bytes, go.importObject);
    running = go.run(instance);
    void running.then(() => reject(new Error('Go module exited before initialization')), reject);
    module = await ready;
  } finally { delete (globalThis as unknown as Record<string, unknown>)[key]; }
  let wakeup = () => {};
  const backend = module.create(capacity, () => wakeup());
  if (!backend) { module.shutdown(); await running; throw new Error('Go module rejected instance creation'); }
  const terminals = new Map<bigint, ReadResult>();
  const instance: Instance = {
    setWakeup: callback => { wakeup = callback; },
    open: (method: Method, timeoutMs?: number) => BigInt(backend.open(method.path, method.requestStream, method.responseStream, timeoutMs ?? -1)),
    openWithRequest: (method, data, timeoutMs) => {
      const [call, status] = backend.openWithRequest(method.path, method.requestStream,
        method.responseStream, timeoutMs ?? -1, data);
      return { call: BigInt(call), status };
    },
    send: (call, data) => backend.send(call.toString(), data),
    halfClose: call => backend.halfClose(call.toString()),
    receive: call => {
      const terminal = terminals.get(call);
      if (terminal) { terminals.delete(call); return terminal; }
      const packet = backend.receive(call.toString());
      if (packet === null) return { kind: 'pending' };
      const results = readPacket(packet);
      if (results.length === 2) terminals.set(call, results[1]);
      return results[0];
    },
    cancel: (call, code) => backend.cancel(call.toString(), code),
    release: call => { terminals.delete(call); backend.release(call.toString()); },
    poll: budget => backend.poll(budget),
    // Go handlers run on goroutines; poll only acknowledges notifications and
    // retires completed calls. There is no manual executor to query in Go.
    hasWork: () => false,
    destroy: () => { const status = backend.destroy(); if (status === 0) terminals.clear(); return status; },
  };
  const host = new Host(instance);
  const closeInstance = host.close.bind(host);
  let closing: Promise<void> | undefined;
  host.close = () => closing ??= closeInstance().then(async () => {
    if (!module.shutdown()) throw new Error('Go module still has active instances');
    await running;
  });
  return host;
}
