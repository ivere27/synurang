// Runs one grpc-js client scenario against a grpc-js network server and
// against PluginChannel backed by an in-memory Synurang plugin host, then
// requires identical results: the TypeScript form of "same client code works
// over FFI or network".

import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import * as grpc from "@grpc/grpc-js";
import { create, toBinary } from "@bufbuild/protobuf";
import { anyPack } from "@bufbuild/protobuf/wkt";
import { ErrorSchema } from "./protobuf_es/core_pb.js";
import { StatusSchema } from "./protobuf_es/grpc_status_pb.js";
import { ParityClient, ParityService, type ParityServer } from "./grpc_parity_grpc.js";
import { Req, Res } from "./grpc_parity_lite.js";
import { FfiError, PluginChannel, type PluginChannelHost, type PluginChannelStream } from "./synurang_grpc.js";

type Outcome = Record<string, unknown>;
type Recv = () => Promise<Req | null>;
type Send = (response: Res) => Promise<void>;

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
const settled = () => new Promise<void>((resolve) => setImmediate(resolve));

/** Application failure: core.v1.Error over FFI, status details over the network. */
class AppError extends Error {
  constructor(readonly appCode: number, readonly grpcCode: number, message: string) {
    super(message);
  }
}

// ── Service logic shared by both transports ──────────────────────────────────

const logic = {
  async unary(request: Req): Promise<Res> {
    if (request.name === "error") throw new AppError(4101, grpc.status.ABORTED, "unary failed");
    if (request.name === "unknown-code") throw new AppError(-7, 0, "no grpc code");
    if (request.name === "slow") await sleep(300);
    return new Res({ message: `Hello ${request.name}!`, index: request.count });
  },
  async serverStream(request: Req, send: Send): Promise<void> {
    for (let index = 0; index < request.count; index++) {
      if (request.name === "error" && index === 2) {
        await sleep(20);
        throw new AppError(4102, grpc.status.ABORTED, "server stream failed");
      }
      await send(new Res({ message: `${request.name}#${index}`, index }));
    }
  },
  async clientStream(recv: Recv): Promise<Res> {
    const names: string[] = [];
    for (let request = await recv(); request !== null; request = await recv()) {
      if (request.name === "error") throw new AppError(4103, grpc.status.ABORTED, "client stream failed");
      names.push(request.name);
    }
    return new Res({ message: names.join(","), index: names.length });
  },
  async bidi(recv: Recv, send: Send): Promise<void> {
    for (let request = await recv(); request !== null; request = await recv()) {
      if (request.name === "error") {
        await sleep(20);
        throw new AppError(4104, grpc.status.RESOURCE_EXHAUSTED, "bidi failed");
      }
      await send(new Res({ message: `echo:${request.name}`, index: request.count }));
    }
  },
};

function coreError(error: AppError): Uint8Array {
  return toBinary(ErrorSchema, create(ErrorSchema, {
    code: error.appCode,
    message: error.message,
    grpcCode: error.grpcCode,
  }));
}

// ── Network: grpc-js server ──────────────────────────────────────────────────

/** What grpc-go sends for status.New(code, msg).WithDetails(&corev1.Error{...}). */
function serverError(error: unknown): Partial<grpc.StatusObject> {
  if (!(error instanceof AppError)) return { code: grpc.status.INTERNAL, details: String(error) };
  const code = error.grpcCode > 0 && error.grpcCode <= 16 ? error.grpcCode : grpc.status.UNKNOWN;
  const detail = anyPack(ErrorSchema, create(ErrorSchema, {
    code: error.appCode,
    message: error.message,
    grpcCode: error.grpcCode,
  }));
  const metadata = new grpc.Metadata();
  metadata.set("grpc-status-details-bin", Buffer.from(toBinary(StatusSchema, create(StatusSchema, {
    code,
    message: error.message,
    details: [detail],
  }))));
  return { code, details: error.message, metadata };
}

function reader(stream: AsyncIterable<unknown>): Recv {
  const iterator = stream[Symbol.asyncIterator]();
  return async () => {
    const next = await iterator.next();
    return next.done ? null : (next.value as Req);
  };
}

const networkServer: ParityServer = {
  unary(call, callback) {
    logic.unary(call.request).then((response) => callback(null, response), (error) => callback(serverError(error)));
  },
  serverStream(call) {
    logic.serverStream(call.request, async (response) => {
      call.write(response);
    }).then(() => call.end(), (error) => call.emit("error", serverError(error)));
  },
  clientStream(call, callback) {
    logic.clientStream(reader(call)).then((response) => callback(null, response), (error) => callback(serverError(error)));
  },
  bidi(call) {
    logic.bidi(reader(call), async (response) => {
      call.write(response);
    }).then(() => call.end(), (error) => call.emit("error", serverError(error)));
  },
};

// ── FFI: in-memory Synurang plugin host ──────────────────────────────────────

function pluginError(error: unknown): unknown {
  return error instanceof AppError ? FfiError.fromPayload(coreError(error)) : error;
}

/** Bounded-lifetime queue with the plugin ABI's EOF and error semantics. */
class Pipe<T> {
  private readonly items: T[] = [];
  private readonly waiters: { resolve: (item: T | null) => void; reject: (error: unknown) => void }[] = [];
  private ended = false;
  private failure: { error: unknown } | undefined;

  push(item: T): void {
    if (this.ended || this.failure !== undefined) throw new Error("stream is closed");
    const waiter = this.waiters.shift();
    if (waiter) waiter.resolve(item);
    else this.items.push(item);
  }

  end(): void {
    if (this.ended || this.failure !== undefined) return;
    this.ended = true;
    for (const waiter of this.waiters.splice(0)) waiter.resolve(null);
  }

  fail(error: unknown): void {
    if (this.ended || this.failure !== undefined) return;
    this.failure = { error };
    for (const waiter of this.waiters.splice(0)) waiter.reject(error);
  }

  next(): Promise<T | null> {
    if (this.items.length > 0) return Promise.resolve(this.items.shift()!);
    if (this.failure !== undefined) return Promise.reject(this.failure.error);
    if (this.ended) return Promise.resolve(null);
    return new Promise((resolve, reject) => this.waiters.push({ resolve, reject }));
  }
}

class MemoryPluginHost implements PluginChannelHost {
  readonly calls: string[] = [];

  async invoke(serviceName: string, methodName: string, data: Uint8Array): Promise<Uint8Array> {
    this.calls.push(`${serviceName} ${methodName}`);
    try {
      return (await logic.unary(Req.fromBinary(data))).toBinary();
    } catch (error) {
      throw pluginError(error);
    }
  }

  openStream(serviceName: string, methodName: string): PluginChannelStream {
    this.calls.push(`${serviceName} ${methodName}`);
    const requests = new Pipe<Uint8Array>();
    const responses = new Pipe<Uint8Array>();
    const recv: Recv = async () => {
      const data = await requests.next();
      return data === null ? null : Req.fromBinary(data);
    };
    const send: Send = async (response) => responses.push(response.toBinary());
    let handler: Promise<void>;
    switch (methodName) {
      case ParityService.serverStream.path:
        handler = recv().then((request) => logic.serverStream(request ?? new Req(), send));
        break;
      case ParityService.clientStream.path:
        handler = logic.clientStream(recv).then(send);
        break;
      case ParityService.bidi.path:
        handler = logic.bidi(recv, send);
        break;
      default:
        throw new FfiError(`no stream handler for ${methodName}`, 0, grpc.status.UNIMPLEMENTED);
    }
    handler.then(() => responses.end(), (error) => {
      requests.end();
      responses.fail(pluginError(error));
    });
    return {
      send: (data) => requests.push(new Uint8Array(data)),
      recv: () => responses.next(),
      closeSend: () => requests.end(),
      close: () => {
        requests.end();
        responses.end();
      },
    };
  }
}

// ── The client scenario: identical code for both transports ──────────────────

function describeError(error: grpc.ServiceError | null | undefined): Outcome | null {
  if (!error) return null;
  const ffi = FfiError.fromStatus(error);
  return {
    code: error.code,
    details: error.details,
    message: error.message,
    statusDetails: error.metadata.get("grpc-status-details-bin").map((value) => Buffer.from(value).toString("hex")),
    ffi: ffi && { code: ffi.code, grpcCode: ffi.grpcCode, message: ffi.message },
  };
}

function describeResponse(response: Res | undefined): Outcome | undefined {
  return response && { message: response.message, index: response.index };
}

function unary(client: ParityClient, request: Req, options: Partial<grpc.CallOptions> = {}): Promise<Outcome> {
  return new Promise((resolve) => {
    const events: string[] = [];
    const call = client.unary(request, new grpc.Metadata(), options, (error, response) => {
      events.push("callback");
      const outcome = { error: describeError(error), response: describeResponse(response), events };
      settled().then(() => resolve(outcome));
    });
    call.on("metadata", () => events.push("metadata"));
    call.on("status", (status: grpc.StatusObject) => events.push(`status:${status.code}`));
  });
}

function cancelledUnary(client: ParityClient): Promise<Outcome> {
  return new Promise((resolve) => {
    const call = client.unary(new Req({ name: "slow" }), (error) => {
      resolve({ code: error?.code, details: error?.details });
    });
    setImmediate(() => call.cancel());
  });
}

function readStream(call: grpc.ClientReadableStream<Res>): Promise<Outcome> {
  return new Promise((resolve) => {
    const events: string[] = [];
    let error: Outcome | null = null;
    call.on("metadata", () => events.push("metadata"));
    call.on("data", (response: Res) => events.push(`data:${response.message}:${response.index}`));
    call.on("error", (failure: grpc.ServiceError) => {
      events.push("error");
      error = describeError(failure);
    });
    call.on("status", (status: grpc.StatusObject) => {
      events.push(`status:${status.code}`);
      settled().then(() => resolve({ events, error }));
    });
  });
}

async function iterate(client: ParityClient): Promise<string[]> {
  const messages: string[] = [];
  for await (const response of client.serverStream(new Req({ name: "iter", count: 3 }))) {
    messages.push((response as Res).message);
  }
  return messages;
}

function writeStream(client: ParityClient, names: string[]): Promise<Outcome> {
  return new Promise((resolve) => {
    const events: string[] = [];
    const call = client.clientStream((error, response) => {
      events.push("callback");
      const outcome = { error: describeError(error), response: describeResponse(response), events };
      settled().then(() => resolve(outcome));
    });
    call.on("metadata", () => events.push("metadata"));
    call.on("status", (status: grpc.StatusObject) => events.push(`status:${status.code}`));
    for (const name of names) call.write(new Req({ name }));
    call.end();
  });
}

async function bidi(client: ParityClient, names: string[]): Promise<Outcome> {
  const call = client.bidi();
  const events: string[] = [];
  let error: Outcome | null = null;
  let received = 0;
  let wake: (() => void) | undefined;
  const done = new Promise<void>((resolve) => {
    call.on("status", (status: grpc.StatusObject) => {
      events.push(`status:${status.code}`);
      settled().then(resolve);
    });
  });
  call.on("metadata", () => events.push("metadata"));
  call.on("data", (response: Res) => {
    events.push(`data:${response.message}:${response.index}`);
    received++;
    wake?.();
  });
  call.on("error", (failure: grpc.ServiceError) => {
    events.push("error");
    error = describeError(failure);
  });
  for (const [index, name] of names.entries()) {
    call.write(new Req({ name, count: index }));
    if (name === "error") break;
    // Interleave: wait for this request's echo before sending the next.
    while (received <= index) await new Promise<void>((resolve) => (wake = resolve));
  }
  call.end();
  await done;
  return { events, error };
}

function unknownMethod(client: ParityClient, path: string): Promise<number | undefined> {
  return new Promise((resolve) => {
    client.makeUnaryRequest(
      path,
      (value: Req) => Buffer.from(value.toBinary()),
      (bytes: Buffer) => Res.fromBinary(bytes),
      new Req(),
      (error) => resolve(error?.code),
    );
  });
}

function waitForReady(client: ParityClient): Promise<string> {
  return new Promise((resolve) => {
    client.waitForReady(Date.now() + 5000, (error) => resolve(error ? error.message : "ready"));
  });
}

async function scenario(client: ParityClient): Promise<Outcome> {
  const deadline = await unary(client, new Req({ name: "slow" }), { deadline: Date.now() + 50 });
  const outcome: Outcome = {
    ready: await waitForReady(client),
    unary: await unary(client, new Req({ name: "world", count: 7 })),
    unaryError: await unary(client, new Req({ name: "error" })),
    unaryUnknownCode: await unary(client, new Req({ name: "unknown-code" })),
    // Deadline details describe transport internals; compare the code.
    deadline: { code: (deadline.error as Outcome | null)?.code, events: deadline.events },
    cancelled: await cancelledUnary(client),
    serverStream: await readStream(client.serverStream(new Req({ name: "s", count: 3 }))),
    serverStreamError: await readStream(client.serverStream(new Req({ name: "error", count: 5 }))),
    serverStreamEmpty: await readStream(client.serverStream(new Req({ name: "none", count: 0 }))),
    iterated: await iterate(client),
    clientStream: await writeStream(client, ["a", "b", "c"]),
    clientStreamEmpty: await writeStream(client, []),
    clientStreamError: await writeStream(client, ["a", "error", "b", "c"]),
    bidi: await bidi(client, ["x", "y", "z"]),
    bidiError: await bidi(client, ["x", "error"]),
    unknownMethod: await unknownMethod(client, "/parity.v1.Parity/Missing"),
    unknownService: await unknownMethod(client, "/parity.v1.Missing/Missing"),
  };
  client.close();
  try {
    client.unary(new Req(), () => undefined);
    outcome.closed = "call accepted";
  } catch (error) {
    outcome.closed = (error as Error).message;
  }
  return outcome;
}

function tracingInterceptor(trace: string[]): grpc.Interceptor {
  return (options, nextCall) => {
    trace.push(options.method_definition.path);
    return new grpc.InterceptingCall(nextCall(options));
  };
}

// ── FFI-only behavior ────────────────────────────────────────────────────────

function ffiClient(host: PluginChannelHost, interceptors: grpc.Interceptor[] = []): ParityClient {
  return new ParityClient("synurang", grpc.credentials.createInsecure(), {
    channelOverride: new PluginChannel(host, ParityService),
    interceptors,
  });
}

function unaryError(client: ParityClient, request: Req, options: Partial<grpc.CallOptions> = {}): Promise<grpc.ServiceError> {
  return new Promise((resolve, reject) => {
    client.unary(request, options, (error) => (error ? resolve(error) : reject(new Error("call succeeded"))));
  });
}

async function ffiOnly(): Promise<void> {
  // A synchronous host (such as the generated PluginHost) serves unary calls.
  const syncHost: PluginChannelHost = {
    invoke: (_service, _method, data) => new Res({ message: "sync", index: Req.fromBinary(data).count }).toBinary(),
  };
  const sync = ffiClient(syncHost);
  const response = await new Promise<Res | undefined>((resolve, reject) => {
    sync.unary(new Req({ count: 3 }), (error, value) => (error ? reject(error) : resolve(value)));
  });
  assert.deepEqual(describeResponse(response), { message: "sync", index: 3 });
  const noStreams = await readStream(sync.serverStream(new Req({ count: 1 })));
  assert.equal((noStreams.error as Outcome).code, grpc.status.UNIMPLEMENTED);

  // Host failures without structure map to UNKNOWN; StatusObject-like errors pass through.
  const plain = await unaryError(ffiClient({ invoke: () => { throw new Error("bridge down"); } }), new Req());
  assert.equal(plain.code, grpc.status.UNKNOWN);
  assert.equal(plain.details, "bridge down");
  assert.equal(FfiError.fromStatus(plain), undefined);
  const busy = await unaryError(ffiClient({ invoke: () => Promise.reject({ code: grpc.status.UNAVAILABLE, details: "busy" }) }), new Req());
  assert.equal(busy.code, grpc.status.UNAVAILABLE);
  assert.equal(busy.details, "busy");

  // Plain-text payloads from older plugins still become structured errors.
  const text = await unaryError(ffiClient({ invoke: () => { throw FfiError.fromPayload(Buffer.from("plain failure")); } }), new Req());
  assert.equal(text.code, grpc.status.UNKNOWN);
  assert.equal(text.details, "plain failure");
  const recovered = FfiError.fromStatus(text);
  assert.deepEqual(
    recovered && { code: recovered.code, grpcCode: recovered.grpcCode, message: recovered.message },
    { code: 0, grpcCode: 0, message: "plain failure" },
  );

  // Parent calls propagate deadlines and cancellation.
  const host = new MemoryPluginHost();
  const client = ffiClient(host);
  const parent = Object.assign(new EventEmitter(), { getDeadline: () => Date.now() + 30 });
  const propagatedDeadline = await unaryError(client, new Req({ name: "slow" }), { parent: parent as unknown as grpc.ServerUnaryCall<Req, Res> });
  assert.equal(propagatedDeadline.code, grpc.status.DEADLINE_EXCEEDED);
  const cancellable = Object.assign(new EventEmitter(), { getDeadline: () => Infinity });
  const cancelled = unaryError(client, new Req({ name: "slow" }), { parent: cancellable as unknown as grpc.ServerUnaryCall<Req, Res> });
  setImmediate(() => cancellable.emit("cancelled"));
  const parentCancelled = await cancelled;
  assert.equal(parentCancelled.code, grpc.status.CANCELLED);
  assert.equal(parentCancelled.details, "Cancelled by parent call");

  // An expired deadline or an immediate cancel never reaches the plugin.
  const callsBefore = host.calls.length;
  const expired = await unaryError(client, new Req({ name: "world" }), { deadline: Date.now() - 1 });
  assert.equal(expired.code, grpc.status.DEADLINE_EXCEEDED);
  const expiredStream = await readStream(client.bidi({ deadline: Date.now() - 1 }));
  assert.equal((expiredStream.error as Outcome).code, grpc.status.DEADLINE_EXCEEDED);
  const cancelledNow = await new Promise<grpc.ServiceError | null>((resolve) => {
    const call = client.unary(new Req({ name: "world" }), (error) => resolve(error));
    call.cancel();
  });
  assert.equal(cancelledNow?.code, grpc.status.CANCELLED);
  assert.equal(host.calls.length, callsBefore);

  // Service names passed to the host match the generated plugin symbols.
  assert.ok(host.calls.every((call) => call.startsWith("Parity /parity.v1.Parity/")), host.calls.join("\n"));
  client.close();
}

async function main(): Promise<void> {
  const server = new grpc.Server();
  server.addService(ParityService, networkServer);
  const port = await new Promise<number>((resolve, reject) => {
    server.bindAsync("127.0.0.1:0", grpc.ServerCredentials.createInsecure(), (error, bound) => (error ? reject(error) : resolve(bound)));
  });

  const networkTrace: string[] = [];
  const network = await scenario(new ParityClient(`127.0.0.1:${port}`, grpc.credentials.createInsecure(), {
    interceptors: [tracingInterceptor(networkTrace)],
  }));
  server.forceShutdown();

  const host = new MemoryPluginHost();
  const ffiTrace: string[] = [];
  const ffi = await scenario(ffiClient(host, [tracingInterceptor(ffiTrace)]));

  assert.deepStrictEqual(ffi, network);
  assert.deepStrictEqual(ffiTrace, networkTrace);
  assert.ok(host.calls.length > 0);
  await ffiOnly();
  console.log("TypeScript grpc-js parity passed (network and Synurang FFI).");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
