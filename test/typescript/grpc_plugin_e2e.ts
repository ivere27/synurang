// Runs one generated grpc-js client against the Go example over the network
// (the TCP process child) and over Synurang FFI (libplugin_go.so loaded with
// koffi), and requires identical results.

import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import * as grpc from "@grpc/grpc-js";
import koffi from "koffi";
import { GoGreeterServiceClient, GoGreeterServiceService } from "./example_grpc.js";
import { GoroutinesRequest, GoroutinesResponse, HelloRequest, HelloResponse, TriggerRequest } from "./example_lite.js";
import { FfiError, PluginChannel, type PluginChannelHost, type PluginChannelStream } from "./synurang_grpc.js";

type Outcome = Record<string, unknown>;
type AsyncFunction = { async: (...args: any[]) => void };

const [pluginPath, childPath] = process.argv.slice(2);
if (!pluginPath || !childPath) throw new Error("usage: grpc_plugin_e2e <libplugin_go.so> <process_child_tcp>");

// ── Synurang plugin host over the C ABI ──────────────────────────────────────

function loadPlugin(path: string, service: string): PluginChannelHost {
  const lib = koffi.load(path);
  const free = lib.func("void Synurang_Free(void *ptr)");
  const invoke = lib.func(`void *Synurang_Invoke_${service}(const char *method, const uint8_t *data, int data_len, _Out_ int *resp_len)`);
  const open = lib.func(`uint64_t Synurang_Stream_${service}_Open(const char *method)`);
  const send = lib.func("int Synurang_Stream_Send(uint64_t handle, const uint8_t *data, int data_len)");
  const recv = lib.func("void *Synurang_Stream_Recv(uint64_t handle, _Out_ int *resp_len, _Out_ int *status)");
  const closeSend = lib.func("void Synurang_Stream_CloseSend(uint64_t handle)");
  const close = lib.func("void Synurang_Stream_Close(uint64_t handle)");

  // Blocking plugin calls run on koffi's worker threads.
  const call = <T>(fn: AsyncFunction, ...args: unknown[]) =>
    new Promise<T>((resolve, reject) => {
      fn.async(...args, (error: unknown, result: T) => (error ? reject(error) : resolve(result)));
    });

  const take = (pointer: unknown, length: number): Uint8Array => {
    if (pointer === null) return new Uint8Array(0);
    try {
      return length > 0 ? new Uint8Array(koffi.view(pointer, length)).slice() : new Uint8Array(0);
    } finally {
      free(pointer);
    }
  };

  return {
    async invoke(serviceName, methodName, data) {
      assert.equal(serviceName, service);
      const length = [0];
      const pointer = await call<unknown>(invoke, methodName, data, data.length, length);
      if (pointer === null && length[0] !== 0) throw new FfiError("plugin returned nil");
      const bytes = take(pointer, Math.abs(length[0]));
      if (length[0] < 0) throw FfiError.fromPayload(bytes);
      return bytes;
    },
    async openStream(serviceName, methodName): Promise<PluginChannelStream> {
      assert.equal(serviceName, service);
      const handle = await call<number | bigint>(open, methodName);
      if (handle === 0 || handle === 0n) throw new Error(`failed to open stream for ${methodName}`);
      return {
        async send(data) {
          const result = await call<number>(send, handle, data, data.length);
          if (result !== 0) throw new Error(`stream send failed with code ${result}`);
        },
        async recv() {
          const length = [0];
          const status = [0];
          const pointer = await call<unknown>(recv, handle, length, status);
          const bytes = take(pointer, length[0]);
          if (status[0] === 0) return bytes;
          if (status[0] === 1) return null;
          if (status[0] < 0 && bytes.length > 0) throw FfiError.fromPayload(bytes);
          throw new Error(`stream error with status ${status[0]}`);
        },
        async closeSend() {
          await call<void>(closeSend, handle);
        },
        close() {
          close(handle);
        },
      };
    },
  };
}

// ── Go gRPC server over the network ──────────────────────────────────────────

function startNetworkServer(path: string): Promise<{ address: string; child: ChildProcess }> {
  const child = spawn(path, [], { env: { ...process.env, SYNURANG_IPC: "tcp" }, stdio: ["ignore", "pipe", "ignore"] });
  return new Promise((resolve, reject) => {
    let output = "";
    child.stdout!.setEncoding("utf8");
    child.stdout!.on("data", (chunk: string) => {
      output += chunk;
      const port = /SYNURANG_PORT:(\d+)/.exec(output)?.[1];
      if (port) resolve({ address: `127.0.0.1:${port}`, child });
    });
    child.once("error", reject);
    child.once("exit", (code) => reject(new Error(`network server exited with ${code}`)));
  });
}

// ── One client scenario for both transports ──────────────────────────────────

function describeError(error: grpc.ServiceError | null | undefined): Outcome | undefined {
  if (!error) return undefined;
  const ffi = FfiError.fromStatus(error);
  return { code: error.code, details: error.details, ffi: ffi && { code: ffi.code, grpcCode: ffi.grpcCode, message: ffi.message } };
}

/** The servers identify themselves ("go-plugin", "go-process-tcp"); compare everything else. */
function describeHello(response: HelloResponse | undefined): Outcome | undefined {
  return response && { message: response.message, from: response.from === "" ? "" : "<source>" };
}

function unary<Request, Response>(
  invoke: (request: Request, callback: grpc.requestCallback<Response>) => grpc.ClientUnaryCall,
  request: Request,
): Promise<{ error: grpc.ServiceError | null; response?: Response }> {
  return new Promise((resolve) => {
    invoke(request, (error, response) => resolve({ error, response }));
  });
}

function collect(stream: grpc.ClientReadableStream<HelloResponse>): Promise<Outcome> {
  return new Promise((resolve) => {
    const messages: string[] = [];
    let error: Outcome | undefined;
    stream.on("data", (response: HelloResponse) => messages.push(response.message));
    stream.on("error", (failure: grpc.ServiceError) => (error = describeError(failure)));
    stream.on("status", (status: grpc.StatusObject) => {
      setImmediate(() => resolve({ messages, status: status.code, error }));
    });
  });
}

function clientStream(client: GoGreeterServiceClient, names: string[]): Promise<Outcome> {
  return new Promise((resolve) => {
    const call = client.barClientStream((error, response) => {
      resolve({ error: describeError(error), response: describeHello(response) });
    });
    for (const name of names) call.write(new HelloRequest({ name }));
    call.end();
  });
}

async function bidi(client: GoGreeterServiceClient, requests: HelloRequest[]): Promise<Outcome> {
  const call = client.barBidiStream();
  const messages: string[] = [];
  let error: Outcome | undefined;
  let wake: (() => void) | undefined;
  const status = new Promise<number>((resolve) => {
    call.on("status", (result: grpc.StatusObject) => setImmediate(() => resolve(result.code)));
  });
  call.on("data", (response: HelloResponse) => {
    messages.push(response.message);
    wake?.();
  });
  call.on("error", (failure: grpc.ServiceError) => {
    error = describeError(failure);
    wake?.();
  });
  for (const [index, request] of requests.entries()) {
    call.write(request);
    if (request.name === "trigger_error") break;
    while (messages.length <= index && error === undefined) {
      await new Promise<void>((resolve) => (wake = resolve));
    }
  }
  call.end();
  return { messages, status: await status, error };
}

async function greeter(client: GoGreeterServiceClient): Promise<Outcome> {
  const ready = await new Promise<string>((resolve) => {
    client.waitForReady(Date.now() + 10_000, (error) => resolve(error ? error.message : "ready"));
  });
  const bar = await unary<HelloRequest, HelloResponse>((request, callback) => client.bar(request, callback), new HelloRequest({ name: "World" }));
  const trigger = await unary<TriggerRequest, HelloResponse>((request, callback) => client.trigger(request, callback), new TriggerRequest());
  const goroutines = await unary<GoroutinesRequest, GoroutinesResponse>((request, callback) => client.getGoroutines(request, callback), new GoroutinesRequest());
  const expired = await collect(client.barServerStream(new HelloRequest({ name: "late" }), { deadline: Date.now() - 1 }));
  return {
    ready,
    bar: { error: describeError(bar.error), response: describeHello(bar.response) },
    trigger: { error: describeError(trigger.error), response: describeHello(trigger.response) },
    goroutines: { count: goroutines.response?.count, message: goroutines.response?.message.replace(/^\S+ /, "<source> ") },
    serverStream: await collect(client.barServerStream(new HelloRequest({ name: "Kim" }))),
    clientStream: await clientStream(client, ["a", "b", "c"]),
    bidi: await bidi(client, [new HelloRequest({ name: "x", language: "ko" }), new HelloRequest({ name: "y", language: "ja" })]),
    expired: { messages: expired.messages, status: expired.status },
  };
}

async function main(): Promise<void> {
  const { address, child } = await startNetworkServer(childPath);
  try {
    const networkClient = new GoGreeterServiceClient(address, grpc.credentials.createInsecure());
    const network = await greeter(networkClient);
    networkClient.close();

    const ffi = new GoGreeterServiceClient("synurang", grpc.credentials.createInsecure(), {
      channelOverride: new PluginChannel(loadPlugin(pluginPath, "GoGreeterService"), GoGreeterServiceService),
    });
    assert.deepStrictEqual(await greeter(ffi), network);
    assert.equal((network.bar as Outcome).error, undefined);
    assert.equal((network.expired as Outcome).status, grpc.status.DEADLINE_EXCEEDED);

    // Structured plugin errors arrive as standard ServiceErrors.
    const aborted = (code: number, message: string) => ({
      code: grpc.status.ABORTED,
      details: message,
      ffi: { code, grpcCode: grpc.status.ABORTED, message },
    });
    const failed = await unary<HelloRequest, HelloResponse>((request, callback) => ffi.bar(request, callback), new HelloRequest({ name: "trigger_error" }));
    assert.deepStrictEqual(describeError(failed.error), aborted(4101, "go unary ffi error"));
    assert.deepStrictEqual((await collect(ffi.barServerStream(new HelloRequest({ name: "trigger_error" })))).error, aborted(4102, "go server stream ffi error"));
    assert.deepStrictEqual((await clientStream(ffi, ["a", "trigger_error", "b"])).error, aborted(4103, "go client stream ffi error"));
    const bidiError = await bidi(ffi, [new HelloRequest({ name: "x" }), new HelloRequest({ name: "trigger_error" })]);
    assert.deepStrictEqual(bidiError.messages, ["Hello, x!"]);
    assert.deepStrictEqual(bidiError.error, aborted(4104, "go bidi stream ffi error"));
    ffi.close();
  } finally {
    child.kill();
  }
  console.log("TypeScript grpc-js client passed over Go gRPC (network) and the Go plugin (FFI).");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
