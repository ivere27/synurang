import assert from 'node:assert/strict';
import * as grpc from '@grpc/grpc-js';
import { CallsClient, CallsService } from './conformance_grpc.js';
import { Value } from './conformance_lite.js';
import { PluginChannel } from './synurang_grpc.js';

export async function grpcConformance(create) {
  const host = await create();
  const client = new CallsClient('synurang', grpc.credentials.createInsecure(), {
    channelOverride: new PluginChannel(host, CallsService),
  });
  const unary = (method, number, options = {}) => new Promise((resolve, reject) => {
    client[method](new Value({ value: number }), options, (error, response) => error ? reject(error) : resolve(response));
  });
  try {
    assert.equal((await unary('unary', 42)).value, 42);
    await assert.rejects(unary('fail', 0), error => error.code === 7 && error.metadata.get('grpc-status-details-bin').length === 1);
    await assert.rejects(unary('unary', -1), error => error.code === 7);
    let expected = 0;
    for await (const response of client.server(new Value({ value: 25 }))) assert.equal(response.value, expected++);
    assert.equal(expected, 25);
    const result = await new Promise((resolve, reject) => {
      const call = client.client((error, response) => error ? reject(error) : resolve(response));
      for (let i = 0; i < 20; ++i) call.write(new Value({ value: i }));
      call.end();
    });
    assert.equal(result.value, 190);
    const early = await new Promise((resolve, reject) => {
      const call = client.client((error, response) => error ? reject(error) : resolve(response));
      call.write(new Value({ value: -2 }));
      for (let i = 0; i < 100; ++i) call.write(new Value({ value: i }));
      call.end();
    });
    assert.equal(early.value, 42);
    const bidi = client.bidi();
    const next = () => new Promise((resolve, reject) => { bidi.once('data', resolve); bidi.once('error', reject); });
    const first = next();
    bidi.write(new Value({ value: 123 }));
    assert.equal((await first).value, 123);
    bidi.end();
    await new Promise((resolve, reject) => { bidi.on('end', resolve); bidi.on('error', reject); });
    await assert.rejects(unary('wait', 0, { deadline: Date.now() + 30 }), error => error.code === 4);
    await assert.rejects(new Promise((resolve, reject) => {
      const call = client.wait(new Value(), error => error ? reject(error) : resolve());
      setTimeout(() => call.cancel(), 10);
    }), error => error.code === 1);
  } finally { client.close(); await host.close(); }
}
