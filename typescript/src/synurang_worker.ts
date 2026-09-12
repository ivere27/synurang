import { RpcError, RequestClosedError, type ByteCall, type CallOptions, type Method, type Transport } from './synurang_runtime.js';

/** Implemented by browser Worker/MessagePort and Node worker_threads ports. */
export interface WorkerPort {
  postMessage(message: unknown, transfer?: any[]): void;
  addEventListener?(name: string, listener: (event: any) => void): void;
  removeEventListener?(name: string, listener: (event: any) => void): void;
  on?(name: string, listener: (...args: any[]) => void): unknown;
  off?(name: string, listener: (...args: any[]) => void): unknown;
  start?(): void;
  terminate?(): unknown;
  close?(): void;
}
type Wire = { synurang: 1; id: number; op: string; call?: number;
  method?: Method; timeoutMs?: number; code?: number; data?: Uint8Array };
type Reply = { synurang: 1; id: number; value?: unknown;
  error?: { name?: string; code: number; message: string; details?: Uint8Array } };
function listen(port: WorkerPort, receive: (message: any) => void, fail?: (error: Error) => void): () => void {
  if (port.addEventListener) {
    const message = (event: MessageEvent) => receive(event.data);
    const error = () => fail?.(new Error('Synurang worker connection failed'));
    port.addEventListener('message', message);
    port.addEventListener('error', error);
    port.addEventListener('messageerror', error);
    port.start?.();
    return () => {
      port.removeEventListener?.('message', message);
      port.removeEventListener?.('error', error);
      port.removeEventListener?.('messageerror', error);
    };
  }
  if (!port.on) throw new Error('Unsupported worker port');
  const error = (value: unknown) => fail?.(value instanceof Error ? value : new Error('Synurang worker exited'));
  port.on('message', receive);
  port.on('error', error);
  port.on('exit', error);
  port.on('close', error);
  return () => {
    port.off?.('message', receive); port.off?.('error', error);
    port.off?.('exit', error); port.off?.('close', error);
  };
}

/** Owns a dedicated worker connection. close waits for provider cleanup, then
 * terminates the worker (or closes a MessagePort). No foreign pointer is sent. */
export class WorkerHost implements Transport {
  private sequence = 0;
  private callSequence = 0;
  private pending = new Map<number, { resolve(value: any): void; reject(error: unknown): void }>();
  private calls = new Set<ByteCall>();
  private retiring = new Set<Promise<unknown>>();
  private retirementError?: unknown;
  private failure?: RpcError;
  private closing?: Promise<void>;
  private readonly unsubscribe: () => void;
  constructor(private readonly port: WorkerPort) {
    this.unsubscribe = listen(port, (reply: Reply) => {
      if (reply?.synurang !== 1) return;
      const pending = this.pending.get(reply.id);
      if (!pending) return;
      this.pending.delete(reply.id);
      if (reply.error) pending.reject(reply.error.name === 'RequestClosedError' ? new RequestClosedError() :
        new RpcError(reply.error.code, reply.error.message, reply.error.details));
      else pending.resolve(reply.value);
    }, error => this.fail(new RpcError(14, error.message)));
  }
  private fail(error: RpcError): void {
    this.failure = error;
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
  }
  private request(op: string, fields: Partial<Wire> = {}, interrupts?: Set<(error: RpcError) => void>): Promise<any> {
    if (this.failure) return Promise.reject(this.failure);
    const id = ++this.sequence;
    return new Promise((resolve, reject) => {
      const interrupt = (error: RpcError) => {
        this.pending.delete(id);
        interrupts?.delete(interrupt);
        reject(error);
      };
      interrupts?.add(interrupt);
      this.pending.set(id, {
        resolve: value => { interrupts?.delete(interrupt); resolve(value); },
        reject: error => { interrupts?.delete(interrupt); reject(error); },
      });
      try {
        const data = fields.data?.slice();
        this.port.postMessage({ ...fields, data, synurang: 1, id, op }, data ? [data.buffer] : []);
      } catch (error) { this.pending.delete(id); interrupts?.delete(interrupt); reject(error); }
    });
  }
  private retire(promise: Promise<unknown>): void {
    this.retiring.add(promise);
    void promise.then(() => this.retiring.delete(promise), error => {
      this.retiring.delete(promise);
      this.retirementError ??= error;
    });
  }
  async open(method: Method, options: CallOptions = {}): Promise<ByteCall> {
    if (this.closing) throw new RpcError(14, 'Host is closed');
    if (options.signal?.aborted) throw new RpcError(1, 'Call cancelled');
    if (options.timeoutMs !== undefined &&
        (!Number.isSafeInteger(options.timeoutMs) || options.timeoutMs < 0))
      throw new RangeError('timeoutMs must be a nonnegative safe integer');
    const call = ++this.callSequence;
    let error: RpcError | undefined;
    let closed = false, ended = false;
    let closing: Promise<void> | undefined;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const interrupts = new Set<(error: RpcError) => void>();
    const cancel = (code = 1) => {
      if (closed || ended || error) return;
      error = new RpcError(code, code === 4 ? 'Deadline exceeded' : 'Call cancelled');
      detach();
      for (const interrupt of [...interrupts]) interrupt(error);
      void this.request('cancel', { call, code }).catch(() => {});
    };
    const abort = () => cancel(1);
    const detach = () => {
      options.signal?.removeEventListener('abort', abort);
      if (timer !== undefined) clearTimeout(timer);
    };
    const opening = this.request('open', { call, method, timeoutMs: options.timeoutMs }, interrupts);
    options.signal?.addEventListener('abort', abort, { once: true });
    if (options.timeoutMs !== undefined) {
      const deadline = performance.now() + options.timeoutMs;
      const expire = () => {
        const remaining = deadline - performance.now();
        if (remaining <= 0) cancel(4);
        else timer = setTimeout(expire, Math.min(remaining, 2 ** 31 - 1));
      };
      if (options.timeoutMs === 0) cancel(4);
      else timer = setTimeout(expire, Math.min(options.timeoutMs, 2 ** 31 - 1));
    }
    try { await opening; }
    catch (failure) {
      detach();
      // An interrupted open can still create its native call later. Retire it
      // in message order without delaying the caller's cancellation response.
      this.retire(this.request('release', { call }));
      throw failure;
    }
    const operation = async (op: string, data?: Uint8Array) => {
      if (error) throw error;
      if (closed) throw new RpcError(1, 'Call is closed');
      try {
        const value = await this.request(op, { call, data }, interrupts);
        if (error) throw error;
        return value;
      } catch (failure) { throw error ?? failure; }
    };
    const remote: ByteCall = {
      send: data => operation('send', data),
      halfClose: () => operation('halfClose'),
      recv: async () => {
        if (ended) return null;
        try {
          const result = await operation('recv');
          if (result === null) { ended = true; detach(); }
          return result;
        } catch (failure) { detach(); throw failure; }
      },
      cancel,
      close: () => {
        if (!closing) {
          if (!ended && !error) error = new RpcError(1, 'Call is closed');
          closed = true;
          detach();
          for (const interrupt of [...interrupts]) interrupt(error ?? new RpcError(1, 'Call is closed'));
          this.calls.delete(remote);
          // Local close releases the caller immediately. The host retains and
          // awaits remote cleanup before it is allowed to terminate the worker.
          this.retire(this.request('release', { call }));
          closing = Promise.resolve();
        }
        return closing;
      },
    };
    this.calls.add(remote);
    if (this.closing) { await remote.close(); throw new RpcError(14, 'Host is closed'); }
    if (error) { await remote.close(); throw error; }
    return remote;
  }
  close(): Promise<void> {
    if (!this.closing) this.closing = Promise.resolve().then(async () => {
      try {
        await Promise.all([...this.calls].map(call => call.close()));
        while (this.retiring.size) await Promise.all([...this.retiring]);
        if (this.retirementError) throw this.retirementError;
        await this.request('close');
      } finally {
        this.unsubscribe();
        this.fail(new RpcError(14, 'Host is closed'));
        await this.port.terminate?.();
        this.port.close?.();
      }
    });
    return this.closing;
  }
}

/** Run in a dedicated worker with self (browser) or parentPort (Node).
 * The factory may create a WASM, native or language-specific transport. */
export function serveWorker(port: WorkerPort,
    factory: () => Promise<Transport & { close(): Promise<void> }> | (Transport & { close(): Promise<void> })): void {
  const ready = Promise.resolve().then(factory);
  // Attach a rejection handler before the first request arrives.
  void ready.catch(() => {});
  const calls = new Map<number, Promise<ByteCall>>();
  let closing = false;
  listen(port, (message: Wire) => {
    if (message?.synurang !== 1) return;
    void (async () => {
      let value: unknown;
      try {
        if (message.op === 'open') {
          if (closing) throw new RpcError(14, 'Host is closed');
          if (calls.has(message.call!)) throw new RpcError(3, 'Duplicate call');
          const opening = ready.then(host => host.open(message.method!, { timeoutMs: message.timeoutMs }));
          calls.set(message.call!, opening);
          try { await opening; } catch (error) { calls.delete(message.call!); throw error; }
        } else if (message.op === 'close') {
          closing = true;
          await Promise.allSettled([...calls.values()]);
          await (await ready).close();
          calls.clear();
        } else {
          const opening = calls.get(message.call!);
          if (!opening) {
            if (message.op !== 'release' && message.op !== 'cancel') throw new RpcError(1, 'Call is closed');
          } else {
            const call = await opening;
            switch (message.op) {
              case 'send': await call.send(message.data!); break;
              case 'recv': value = await call.recv(); break;
              case 'halfClose': await call.halfClose(); break;
              case 'cancel': call.cancel(message.code); break;
              case 'release': await call.close(); calls.delete(message.call!); break;
              default: throw new RpcError(3, 'Unknown worker operation');
            }
          }
        }
        port.postMessage({ synurang: 1, id: message.id, value }, value instanceof Uint8Array ? [value.buffer] : []);
      } catch (failure) {
        const error = failure as Partial<RpcError>;
        port.postMessage({ synurang: 1, id: message.id, error: {
          name: error.name,
          code: typeof error.code === 'number' ? error.code : 13,
          message: error.message ?? String(failure), details: error.details,
        } });
      }
    })();
  });
}
