import { Host } from './synurang_runtime.js';

const method = { path: '/test/Wait', requestStream: true, responseStream: true };
function check(condition, message) { if (!condition) throw new Error(message); }

/** Ready work must resume parked consumers within the watchdog, without an
 * idle timer. This is a scheduling contract, not a latency benchmark. */
export async function idlePromotion() {
  let opened = 0n, polls = 0, receives = 0, ready = false, output = false, destroyed = false;
  let observer;
  const instance = {
    setWakeup() {},
    open() { ready = true; return ++opened; },
    send() { ready = true; return 0; },
    halfClose() { ready = true; return 0; },
    cancel() { ready = true; }, release() { ready = true; },
    receive() {
      ++receives;
      if (!output) return { kind: 'pending' };
      output = false;
      ready = true; // Consuming output can unblock a paused provider.
      return { kind: 'message', data: Uint8Array.of(8, 7) };
    },
    hasWork() { return ready; },
    poll(budget) {
      check(!destroyed, 'promoted callback accessed a destroyed instance');
      check(budget > 0 && budget <= 64, 'promoted callback exceeded its task budget');
      const processed = Number(ready);
      ready = false;
      ++polls;
      observer?.();
      return processed;
    },
    destroy() { destroyed = true; return 0; },
  };
  const host = new Host(instance);
  async function progress(operation, label, idle = true) {
    const before = polls;
    // Read the existing idle boundary before queuing work. A waiting consumer
    // must retain the same promise through promotion; this never calls poll.
    let settled = !idle;
    if (idle) void host.turn().then(() => { settled = true; });
    const result = await operation();
    check(polls === before, `${label}: polling did not yield to the event loop`);
    let timer;
    try {
      await new Promise((resolve, reject) => {
        observer = resolve;
        timer = setTimeout(() => reject(new Error(`${label}: ready work did not wake the host`)), 1000);
      });
      await Promise.resolve();
      check(settled, `${label}: promotion abandoned an existing poll waiter`);
      check(polls > before && !ready, `${label}: ready work was not drained`);
    } finally {
      observer = undefined;
      clearTimeout(timer);
    }
    return result;
  }
  try {
    const first = await progress(() => host.open(method), 'initial open', false);
    const second = await progress(() => host.open(method), 'open while idle');
    await progress(() => first.send(new Uint8Array()), 'send while idle');
    check(receives === 0, 'promotion eagerly consumed response data');
    output = true;
    const response = await progress(() => first.recv(), 'receive frees capacity while idle');
    check(response?.[1] === 7, 'promoted receive changed response data');
    await progress(() => first.halfClose(), 'half-close while idle');
    await progress(() => first.cancel(), 'cancel while idle');
    await progress(() => first.close(), 'release while another call is idle');
    await progress(() => second.cancel(), 'last call cancel while idle');
    await progress(() => second.close(), 'last call release while idle');
    check(receives === 1, 'promotion eagerly consumed response data');
    await progress(() => host.open(method), 'open after idle cleanup', false);
  } finally { await host.close(); }
  const stopped = polls;
  await new Promise(resolve => setTimeout(resolve, 20));
  check(polls === stopped, 'promoted callback ran after close');
}
