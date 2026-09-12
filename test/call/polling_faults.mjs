import assert from 'node:assert/strict';
import { Host } from './synurang_runtime.js';

const pause = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const method = { path: '/test/Wait', requestStream: false, responseStream: false };
const internal = error => error?.code === 13;

function fixture(overrides = () => ({})) {
  const stats = { opened: 0, polls: 0, receives: 0, released: [], destroys: 0 };
  const instance = {
    setWakeup(callback) { stats.wakeup = callback; },
    open() { return BigInt(++stats.opened); },
    send() { return 0; }, halfClose() { return 0; }, cancel() {},
    receive() { ++stats.receives; return { kind: 'pending' }; },
    release(id) { stats.released.push(id); }, hasWork() { return false; },
    poll() { ++stats.polls; return 0; },
    destroy() { ++stats.destroys; return 0; },
  };
  Object.assign(instance, overrides(stats));
  return { stats, host: new Host(instance) };
}

export async function pollingFaults() {
  const unhandled = [];
  const track = error => unhandled.push(error);
  process.on('unhandledRejection', track);
  try {
    // A callback can run inside a WASM/provider entry. It must only post work,
    // including when a second callback arrives during a bounded poll.
    {
      let inside = false, notified = false;
      const { host } = fixture(stats => ({
        open() { inside = true; stats.wakeup(); inside = false; return 1n; },
        hasWork() { assert.equal(inside, false, 'notification re-entered the provider'); return false; },
        poll() {
          inside = true;
          if (!notified) { notified = true; stats.wakeup(); }
          inside = false;
          return 0;
        },
      }));
      try { await host.open(method); await host.turn(); }
      finally { await host.close(); }
    }
    // A quiet open call has no periodic polls. External producers notify the
    // host even when hasWork is false (for example, new Go output).
    {
      const { host, stats } = fixture(() => ({}));
      try {
        const call = await host.open(method);
        await call.send(new Uint8Array());
        await pause(30);
        const idle = stats.polls;
        await pause(30);
        assert.equal(stats.polls, idle, 'quiet call caused periodic polling');
        stats.wakeup();
        await pause(10);
        assert.ok(stats.polls > idle, 'producer notification did not resume polling');
        assert.equal(stats.receives, 0, 'scheduler eagerly received output');
      } finally { await host.close(); }
      const stopped = stats.polls;
      await pause(10);
      assert.equal(stats.polls, stopped);
    }

    // An unobserved background fault must be retained until the caller next
    // touches its call, without becoming an unhandled promise rejection.
    {
      const { host, stats } = fixture(stats => ({
        poll() { ++stats.polls; throw new Error('injected poll failure'); },
      }));
      try {
        const call = await host.open(method);
        await call.send(new Uint8Array());
        await pause(30);
        assert.ok(stats.polls > 0, 'background poll did not run');
        await assert.rejects(call.recv(), internal);
        await assert.rejects(call.send(new Uint8Array()), internal);
        await assert.rejects(host.open(method), internal);
      } finally { await host.close(); }
      const stopped = stats.polls;
      await pause(10);
      assert.equal(stats.polls, stopped, 'failed scheduler kept polling after close');
      assert.deepEqual(stats.released, [1n]);
      assert.equal(stats.destroys, 1);
    }

    // A successful terminal status already consumed by one RPC is immutable
    // even if a different RPC later discovers a module-wide polling fault.
    {
      const { host } = fixture(() => ({
        receive(id) { return id === 1n ? { kind: 'finished', code: 0, data: new Uint8Array() }
          : { kind: 'pending' }; },
        poll() { throw new Error('second call poll failure'); },
      }));
      try {
        const completed = await host.open(method);
        assert.equal(await completed.recv(), null);
        const active = await host.open(method);
        await pause(20);
        assert.equal(await completed.recv(), null, 'poll fault rewrote successful EOF');
        await assert.rejects(active.recv(), internal);
      } finally { await host.close(); }
    }

    // Reading a terminal status can itself wake the scheduler. Record that
    // status before hasWork can throw at the next scheduling boundary.
    for (const operation of ['recv', 'send', 'halfClose']) for (const code of [0, 7]) {
      let finished = false;
      const details = Uint8Array.of(18, 3, 98, 97, 100); // core.Error.message = "bad"
      const { host } = fixture(() => ({
        send() { return -1; }, halfClose() { return -1; },
        receive() { finished = true; return { kind: 'finished', code, data: details }; },
        hasWork() { if (finished) throw new Error('terminal-read wake failure'); return false; },
      }));
      const originalStatus = error => {
        assert.equal(error.code, 7);
        assert.equal(error.message, 'bad');
        assert.deepEqual(error.details, details);
        return true;
      };
      try {
        const call = await host.open(method);
        const first = operation === 'send' ? call.send(new Uint8Array()) : call[operation]();
        if (code !== 0) await assert.rejects(first, originalStatus);
        else if (operation === 'recv') assert.equal(await first, null);
        else await assert.rejects(first, error => error.name === 'RequestClosedError');
        await assert.rejects(host.turn(), internal);
        for (let repeat = 0; repeat < 2; ++repeat) {
          if (code !== 0) await assert.rejects(call.recv(), originalStatus);
          else assert.equal(await call.recv(), null, `${operation} wake rewrote successful EOF`);
        }
        await assert.rejects(host.open(method), internal);
      } finally { await host.close(); }
    }

    // A synchronous hasWork exception during initial scheduling must not
    // leave a cached rejected tick that prevents deferred destroy from polling.
    {
      let hints = 0;
      const { host, stats } = fixture(stats => ({
        hasWork() { if (++hints === 1) throw new Error('initial hasWork failure'); return false; },
        destroy() { return ++stats.destroys === 1 ? 3 : 0; },
      }));
      const call = await host.open(method);
      await assert.rejects(call.recv(), internal);
      await host.close();
      assert.equal(stats.destroys, 2);
      assert.ok(stats.polls > 0, 'pending teardown never recovered its polling boundary');
      assert.deepEqual(stats.released, [1n]);
    }

    // Foreign cancel errors must not escape an AbortSignal or timeout callback.
    for (const source of ['direct', 'abort', 'deadline']) {
      const { host } = fixture(() => ({ cancel() { throw new Error('foreign cancel failure'); } }));
      try {
        const unaffected = await host.open(method);
        const controller = new AbortController();
        const call = await host.open(method, source === 'deadline' ? { timeoutMs: 1 }
          : source === 'abort' ? { signal: controller.signal } : {});
        if (source === 'direct') assert.doesNotThrow(() => call.cancel());
        if (source === 'abort') assert.doesNotThrow(() => controller.abort());
        if (source === 'deadline') await pause(20);
        await assert.rejects(call.recv(), error => error?.code === (source === 'deadline' ? 4 : 1));
        await assert.rejects(unaffected.recv(), internal);
        await assert.rejects(host.open(method), internal);
      } finally { await host.close(); }
    }

    // Release failures latch the host fault and are never retried for that
    // handle. Other handles can still be released before successful destroy.
    {
      const { host, stats } = fixture(stats => ({
        release(id) {
          stats.released.push(id);
          if (id === 1n) throw new Error('foreign release failure');
        },
      }));
      const failed = await host.open(method);
      const active = await host.open(method);
      await assert.rejects(failed.close(), internal);
      await failed.close();
      await assert.rejects(active.recv(), internal);
      await assert.rejects(host.open(method), internal);
      await host.close();
      assert.deepEqual(stats.released, [1n, 2n]);
      assert.equal(stats.destroys, 1);
    }

    await pause(10);
    assert.deepEqual(unhandled, [], 'polling fault caused an unhandled rejection');
  } finally { process.off('unhandledRejection', track); }
}
