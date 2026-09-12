import assert from 'node:assert/strict';
import { Host } from './synurang_runtime.js';

const method = { path: '/test/Wait', requestStream: false, responseStream: false };
function fixture(destroy = () => 0) {
  let ready = false, notify;
  const polled = new Promise(resolve => { notify = resolve; });
  const host = new Host({
    setWakeup() {},
    open() { ready = true; return 1n; }, send() { ready = true; return 0; },
    halfClose() { return 0; }, receive() { return { kind: 'pending' }; },
    cancel() {}, release() {}, hasWork() { return ready; },
    poll() { ready = false; notify(); return 1; }, destroy,
  });
  return { host, polled };
}

// No external timer keeps Node alive: a ready poll must itself remain runnable.
const active = fixture();
await active.host.open(method);
await active.polled;
await active.host.close();

// Closing before the posted ready task executes must also retire its ports.
const pending = fixture();
await pending.host.open(method);
await pending.host.close();

// Failed teardown must also stop scheduling and retire ports, while reporting
// the failure instead of claiming the foreign instance was destroyed.
for (const destroy of [() => { throw new Error('destroy failed'); }, () => -7]) {
  const failed = fixture(destroy);
  await failed.host.open(method);
  await assert.rejects(failed.host.close(), error => error?.code === 13);
}
// Deliberately no process.exit(): the runner checks natural process completion.
