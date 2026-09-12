/** Protobuf byte transport shared by native, WASM, workers and RPC adapters. */
export interface Method {
  readonly path: string;
  readonly requestStream: boolean;
  readonly responseStream: boolean;
}
export interface CallOptions {
  signal?: AbortSignal;
  timeoutMs?: number;
}
export class RpcError extends Error {
  constructor(public readonly code: number, message: string,
              public readonly details = new Uint8Array()) {
    super(message);
    this.name = 'RpcError';
  }
}

/** The provider stopped accepting input. Its response/status remain readable. */
export class RequestClosedError extends Error {
  constructor() { super('RPC request side is closed'); this.name = 'RequestClosedError'; }
}
export interface ByteCall {
  send(data: Uint8Array): Promise<void>;
  halfClose(): Promise<void>;
  recv(): Promise<Uint8Array | null>;
  cancel(code?: number): void;
  close(): Promise<void>;
}
export interface Transport {
  open(method: Method, options?: CallOptions): Promise<ByteCall>;
  /** Optional batching of open, one send and half-close. Validate before encoding. */
  openWithRequest?(method: Method, encode: () => Uint8Array, options?: CallOptions): Promise<ByteCall>;
}
export type ReadResult = { kind: 'pending' } | { kind: 'message'; data: Uint8Array }
  | { kind: 'finished'; code: number; data: Uint8Array };

/** Entries never wait for a producer. Returned bytes are owned by JavaScript.
 * A driver copies and frees foreign output before returning from receive(). */
export interface Instance {
  setWakeup(wakeup: () => void): void;
  open(method: Method, timeoutMs?: number): bigint;
  /** Return the call even if a write fails so its authoritative status can be read. */
  openWithRequest?(method: Method, data: Uint8Array, timeoutMs?: number): { call: bigint; status: number };
  send(call: bigint, data: Uint8Array): number;
  halfClose(call: bigint): number;
  receive(call: bigint): ReadResult;
  cancel(call: bigint, code: number): void;
  release(call: bigint): void;
  poll(budget: number): number;
  hasWork(): boolean;
  /** 0 = destroyed, 3 = async producer cleanup still pending. */
  destroy(): number;
}

/** A statically linked Node addon supplies this interface directly. */
export function createLinkedHost(addon: { createInstance(capacity: number): Instance },
    options: { capacity?: number } = {}): Host {
  const capacity = options.capacity ?? 16;
  if (!Number.isInteger(capacity) || capacity < 1 || capacity > 65536)
    throw new RangeError('capacity must be between 1 and 65536');
  return new Host(addon.createInstance(capacity));
}

function statusError(code: number, details = new Uint8Array()): RpcError {
  // Read the message field of core.v1.Error, retaining the original protobuf.
  let message = code === 1 ? 'Call cancelled' : code === 4 ? 'Deadline exceeded' : `RPC failed (${code})`;
  try {
    let pos = 0;
    const uint = () => {
      let result = 0, shift = 0;
      while (pos < details.length && shift < 53) {
        const b = details[pos++];
        result += (b & 127) * 2 ** shift;
        if (!(b & 128)) return result;
        shift += 7;
      }
      throw new Error('Malformed varint');
    };
    while (pos < details.length) {
      const tag = uint();
      if ((tag & 7) === 2) {
        const size = uint();
        if (size > details.length - pos) break;
        if (tag === 18) message = new TextDecoder().decode(details.subarray(pos, pos + size));
        pos += size;
      } else if ((tag & 7) === 0) uint();
      else if ((tag & 7) === 1) pos += 8;
      else if ((tag & 7) === 5) pos += 4;
      else break;
    }
  } catch { /* Keep the transport status even if details are malformed. */ }
  return new RpcError(code, message, details);
}

interface PollTick {
  id: number;
  promise: Promise<void>;
  resolve(): void;
  reject(error: unknown): void;
  timer?: ReturnType<typeof setTimeout>;
  posted: boolean;
}

/** One serialized executor per instance. Open calls progress even while the
 * consumer is not receiving. Each bounded poll yields to the event loop;
 * provider callbacks must themselves return promptly. */
export class Host implements Transport {
  private calls = new Set<LocalCall>();
  private tick?: PollTick;
  private taskSequence = 0;
  private channel?: MessageChannel;
  private closing?: Promise<void>;
  private closed = false;
  private failure?: RpcError;
  readonly openWithRequest?: Transport['openWithRequest'];
  constructor(private readonly instance: Instance) {
    instance.setWakeup(() => this.wake());
    if (instance.openWithRequest) {
      this.openWithRequest = async (method, encode, options = {}) => {
        this.validateOpen(options);
        const data = encode();
        // An application codec may synchronously cancel or close its host.
        this.validateOpen(options);
        const result = instance.openWithRequest!(method, data, options.timeoutMs);
        const call = this.attach(result.call, options);
        try {
          if (result.status === -4) {
            await call.send(data);
            await call.halfClose();
          } else call.acceptInitialRequest(result.status);
          return call;
        } catch (error) {
          await call.close();
          throw error;
        }
      };
    }
  }

  private validateOpen(options: CallOptions): void {
    if (this.closing || this.closed) throw new RpcError(14, 'Host is closed');
    if (this.failure) throw this.failure;
    if (options.timeoutMs !== undefined &&
        (!Number.isSafeInteger(options.timeoutMs) || options.timeoutMs < 0))
      throw new RangeError('timeoutMs must be a nonnegative safe integer');
    if (options.signal?.aborted) throw statusError(1);
  }

  private attach(id: bigint, options: CallOptions): LocalCall {
    if (id === 0n) throw new RpcError(13, 'Module rejected call creation');
    const call = new LocalCall(this, this.instance, id, options);
    this.calls.add(call);
    this.wake();
    return call;
  }

  async open(method: Method, options: CallOptions = {}): Promise<ByteCall> {
    this.validateOpen(options);
    const id = this.instance.open(method, options.timeoutMs);
    return this.attach(id, options);
  }

  /** Internal fault propagation; cleanup must still succeed before unloading. */
  fail(error: unknown): RpcError {
    const failure = this.failure ??= error instanceof RpcError ? error :
      new RpcError(13, error instanceof Error ? error.message : String(error));
    for (const call of this.calls) call.fail(failure);
    this.stopTick(failure);
    return failure;
  }

  /** Internal notification after an operation can make the provider ready. */
  wake(): void {
    if (this.closed || (this.failure && !this.closing)) return;
    // A WASM import can invoke this inside a provider entry, holding its locks.
    // Even hasWork must wait until that entry has returned.
    this.postReady(this.ensureTick());
  }

  private ensureTick(): PollTick {
    if (!this.tick) {
      let resolve!: () => void, reject!: (error: unknown) => void;
      const promise = new Promise<void>((ok, fail) => { resolve = ok; reject = fail; });
      this.tick = { id: ++this.taskSequence, promise, resolve, reject, posted: false };
      void promise.catch(() => {});
    }
    return this.tick;
  }

  private closeChannel(): void {
    this.channel?.port1.close();
    this.channel?.port2.close();
    this.channel = undefined;
  }

  private stopTick(error?: RpcError): void {
    const tick = this.tick;
    this.tick = undefined;
    if (tick?.timer !== undefined) clearTimeout(tick.timer);
    this.closeChannel();
    if (error) tick?.reject(error);
    else tick?.resolve();
  }

  private postReady(tick: PollTick): void {
    if (tick.posted) return;
    if (tick.timer !== undefined) clearTimeout(tick.timer);
    tick.timer = undefined;
    tick.posted = true;
    if (typeof MessageChannel === 'undefined') {
      tick.timer = setTimeout(() => this.runTick(tick), 0);
      return;
    }
    if (!this.channel) {
      this.channel = new MessageChannel();
      this.channel.port1.onmessage = event => {
        const current = this.tick;
        // A cancelled task must never execute a newer tick after teardown or
        // an idle timer promotion. Messages carry the tick's generation.
        if (current && current.id === event.data) this.runTick(current);
      };
    }
    this.channel.port2.postMessage(tick.id);
  }

  private runTick(tick: PollTick): void {
    if (this.tick !== tick) return;
    this.tick = undefined;
    if (tick.timer !== undefined) clearTimeout(tick.timer);
    try {
      if (!this.closed) {
        this.instance.poll(64);
        // An idle instance sleeps until a producer notification or deadline.
        // Leave output in its bounded queue until the consumer receives it.
        if (this.instance.hasWork()) this.wake();
        else if (!this.tick) this.closeChannel();
      }
      tick.resolve();
    } catch (error) { tick.reject(this.fail(error)); }
  }

  /** Internal scheduling boundary, also used to finish asynchronous teardown. */
  turn(): Promise<void> {
    if (this.closed) return Promise.resolve();
    if (this.failure && !this.closing) return Promise.reject(this.failure);
    try {
      const ready = this.instance.hasWork();
      const tick = this.ensureTick();
      // A new request or newly freed output capacity must not wait behind an
      // idle timer. Ready work uses an event-loop task, avoiding timer nesting.
      if (ready) this.postReady(tick);
      return tick.promise;
    } catch (error) { return Promise.reject(this.fail(error)); }
  }

  forget(call: LocalCall): void {
    this.calls.delete(call);
    // Releasing the last call can queue cancellation/destruction callbacks.
    this.wake();
  }

  close(): Promise<void> {
    if (!this.closing) {
      // Defer until closing is set, so no new call can enter during teardown.
      this.closing = Promise.resolve().then(async () => {
        for (const call of this.calls) await call.close();
        while (true) {
          const status = this.instance.destroy();
          if (status === 0) {
            this.closed = true;
            this.stopTick();
            return;
          }
          if (status !== 3) throw new RpcError(13, `Module teardown failed (${status})`);
          await this.turn();
        }
      }).catch(error => { throw this.fail(error); });
    }
    return this.closing;
  }
}

class LocalCall implements ByteCall {
  private released = false;
  private ended = false;
  private error?: RpcError;
  private pending?: Uint8Array;
  private reading = false;
  private sendTail = Promise.resolve();
  private timer?: ReturnType<typeof setTimeout>;
  private readonly abort = () => this.cancel(1);
  constructor(private readonly host: Host, private readonly instance: Instance,
              private readonly id: bigint, private readonly options: CallOptions) {
    options.signal?.addEventListener('abort', this.abort, { once: true });
    if (options.timeoutMs !== undefined) {
      const deadline = performance.now() + options.timeoutMs;
      const expire = () => {
        const remaining = deadline - performance.now();
        if (remaining <= 0) this.cancel(4);
        else this.timer = setTimeout(expire, Math.min(remaining, 2 ** 31 - 1));
      };
      if (options.timeoutMs === 0) this.cancel(4);
      else this.timer = setTimeout(expire, Math.min(options.timeoutMs, 2 ** 31 - 1));
    }
  }
  private check(): void {
    if (this.error) throw this.error;
    if (this.released) throw new RpcError(1, 'Call is closed');
    if (this.ended) throw new RequestClosedError();
  }
  fail(error: RpcError): void {
    if (!this.released && !this.ended && !this.error) this.error = error;
    this.detach();
  }
  private writeError(_status: number): RpcError | RequestClosedError {
    // A terminal RPC can reject the very first send (unknown method or shape).
    // Peek once and keep any message for recv; do not drain the producer here.
    if (!this.pending && !this.ended && !this.error) {
      const result = this.instance.receive(this.id);
      if (result.kind === 'message') this.pending = result.data;
      if (result.kind === 'finished') {
        this.ended = true;
        this.detach();
        if (result.code !== 0) this.error = statusError(result.code, result.data);
      }
      this.host.wake();
    }
    return this.error ?? new RequestClosedError();
  }
  /** Validate a provider-batched initial request using ordinary write policy. */
  acceptInitialRequest(status: number): void {
    this.check();
    if (status !== 0) throw this.writeError(status);
  }
  send(data: Uint8Array): Promise<void> {
    // The caller may reuse its buffer immediately, including while a previous
    // send is waiting on capacity. The transport owns this bounded operation.
    const owned = data.slice();
    const operation = this.sendTail.then(async () => {
      while (true) {
        this.check();
        const status = this.instance.send(this.id, owned);
        if (status === 0) { this.host.wake(); return; }
        if (status !== -4) throw this.writeError(status);
        await this.host.turn();
      }
    });
    this.sendTail = operation.catch(() => {});
    return operation;
  }
  halfClose(): Promise<void> {
    const operation = this.sendTail.then(() => {
      this.check();
      const status = this.instance.halfClose(this.id);
      if (status !== 0) throw this.writeError(status);
      this.host.wake();
    });
    this.sendTail = operation.catch(() => {});
    return operation;
  }
  async recv(): Promise<Uint8Array | null> {
    if (this.reading) throw new Error('Only one receive may be pending per call');
    this.reading = true;
    try {
      while (true) {
        if (this.error) throw this.error;
        if (this.ended) return null;
        this.check();
        if (this.pending) {
          const data = this.pending;
          this.pending = undefined;
          return data;
        }
        const result = this.instance.receive(this.id);
        if (result.kind === 'message') { this.host.wake(); return result.data; }
        if (result.kind === 'finished') {
          this.ended = true;
          this.detach();
          if (result.code !== 0) this.error = statusError(result.code, result.data);
          this.host.wake();
          if (this.error) throw this.error;
          return null;
        }
        await this.host.turn();
      }
    } finally { this.reading = false; }
  }
  cancel(code = 1): void {
    if (this.released || this.ended || this.error) return;
    this.error = statusError(code);
    this.detach();
    try { this.instance.cancel(this.id, code); }
    catch (error) { this.host.fail(error); }
    this.host.wake();
  }
  private detach(): void {
    if (this.timer !== undefined) clearTimeout(this.timer);
    this.options.signal?.removeEventListener('abort', this.abort);
  }
  async close(): Promise<void> {
    if (this.released) return;
    if (!this.ended) this.cancel();
    this.released = true;
    this.detach();
    try { this.instance.release(this.id); }
    catch (error) { throw this.host.fail(error); }
    finally { this.host.forget(this); }
  }
}

export interface Codec<T> { encode(message: T): Uint8Array; decode(data: Uint8Array): T }
export interface Duplex<I, O> {
  send(message: I): Promise<void>;
  halfClose(): Promise<void>;
  recv(): Promise<O | null>;
  readonly responses: AsyncIterable<O>;
  cancel(): void;
  close(): Promise<void>;
}
export async function duplex<I, O>(transport: Transport, method: Method,
    input: Codec<I>, output: Codec<O>, options?: CallOptions): Promise<Duplex<I, O>> {
  const call = await transport.open(method, options);
  return {
    send: message => call.send(input.encode(message)),
    halfClose: () => call.halfClose(),
    async recv() { const data = await call.recv(); return data === null ? null : output.decode(data); },
    responses: {
      async *[Symbol.asyncIterator]() {
        try {
          for (;;) {
            const data = await call.recv();
            if (data === null) return;
            yield output.decode(data);
          }
        } finally { await call.close(); }
      },
    },
    cancel: () => call.cancel(),
    close: () => call.close(),
  };
}
async function single<O>(call: ByteCall, output: Codec<O>): Promise<O> {
  const data = await call.recv();
  if (data === null) throw new RpcError(13, 'RPC completed without a response');
  // A response is only successful once the terminal status has been observed.
  if (await call.recv() !== null) throw new RpcError(13, 'RPC produced multiple responses');
  return output.decode(data);
}
export async function unary<I, O>(transport: Transport, method: Method, request: I,
    input: Codec<I>, output: Codec<O>, options?: CallOptions): Promise<O> {
  const prepared = transport.openWithRequest !== undefined;
  const call = await (prepared
    ? transport.openWithRequest!(method, () => input.encode(request), options)
    : transport.open(method, options));
  try {
    if (!prepared) {
      await call.send(input.encode(request));
      await call.halfClose();
    }
    return await single(call, output);
  } finally { await call.close(); }
}
export async function* serverStream<I, O>(transport: Transport, method: Method, request: I,
    input: Codec<I>, output: Codec<O>, options?: CallOptions): AsyncGenerator<O> {
  const prepared = transport.openWithRequest !== undefined;
  const call = await (prepared
    ? transport.openWithRequest!(method, () => input.encode(request), options)
    : transport.open(method, options));
  try {
    if (!prepared) {
      await call.send(input.encode(request));
      await call.halfClose();
    }
    for (;;) {
      const data = await call.recv();
      if (data === null) return;
      yield output.decode(data);
    }
  } finally { await call.close(); }
}
export async function clientStream<I, O>(transport: Transport, method: Method,
    requests: Iterable<I> | AsyncIterable<I>, input: Codec<I>, output: Codec<O>,
    options?: CallOptions): Promise<O> {
  const call = await transport.open(method, options);
  let stopped = false;
  let stop!: () => void;
  const stopping = new Promise<null>(resolve => { stop = () => resolve(null); });
  const iterator = Symbol.asyncIterator in requests
    ? requests[Symbol.asyncIterator]() : requests[Symbol.iterator]();
  // Read concurrently: a server may finish before it consumes the entire input.
  const sending = (async () => {
    try {
      while (!stopped) {
        const next = await Promise.race([Promise.resolve(iterator.next()), stopping]);
        if (next === null) return;
        if (next.done) break;
        await call.send(input.encode(next.value));
      }
      if (!stopped) await call.halfClose();
    } catch (error) {
      // A generated client and a package host may contain different runtime
      // copies; custom language/worker transports also reconstruct errors.
      if (!(error && typeof error === 'object' && 'name' in error && error.name === 'RequestClosedError')) throw error;
    }
  })();
  const sendFailure = sending.then(() => new Promise<never>(() => {}));
  try { return await Promise.race([single(call, output), sendFailure]); }
  finally {
    stopped = true;
    stop();
    // Generic iterators may ignore cancellation. Request return promptly but
    // do not wait for an iterator stuck in application work to release the RPC.
    try { void Promise.resolve(iterator.return?.()).catch(() => {}); } catch { /* cleanup */ }
    await call.close();
  }
}
