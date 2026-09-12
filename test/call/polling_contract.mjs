import { createWasmHost, instantiateWasm } from './synurang_wasm.js';
import { WorkerHost } from './synurang_worker.js';

const method = (name, requestStream = false, responseStream = false) => ({
  path: `/synurang.test.Calls/${name}`, requestStream, responseStream,
});
const pause = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
function check(condition, message) { if (!condition) throw new Error(message); }

/** Observation never polls or receives: only the host can advance the module. */
export function observeModule(module, report) {
  const counters = {
    polls: 0, sends: 0, halves: 0, cancels: 0, releases: 0,
    destroyed: 0, afterDestroy: 0, processed: 0, budget: 0,
  };
  const wrapped = { ...module };
  for (const [operation, field] of [['send', 'sends'], ['half_close', 'halves'],
      ['cancel', 'cancels'], ['release', 'releases']]) {
    const name = `synurang_module_${operation}`;
    wrapped[name] = (...args) => {
      const result = module[name](...args);
      ++counters[field];
      return result;
    };
  }
  wrapped.synurang_module_poll = (instance, budget) => {
    if (counters.destroyed) ++counters.afterDestroy;
    ++counters.polls;
    counters.budget = budget;
    counters.processed = module.synurang_module_poll(instance, budget);
    report({ ...counters, pending: module.synurang_module_has_work(instance) });
    return counters.processed;
  };
  wrapped.synurang_module_destroy = instance => {
    const status = module.synurang_module_destroy(instance);
    if (status === 0) {
      ++counters.destroyed;
      report({ ...counters, processed: 0, pending: 0 });
    }
    return status;
  };
  return wrapped;
}

export function observations() {
  let latest = { polls: 0, sends: 0, halves: 0, cancels: 0, releases: 0, destroyed: 0, afterDestroy: 0 };
  const history = [];
  const waiting = new Set();
  return {
    get latest() { return latest; },
    report(snapshot) {
      latest = snapshot;
      history.push(snapshot);
      if (history.length > 512) history.shift();
      for (const waiter of [...waiting]) {
        if (waiter.predicate(snapshot)) {
          waiting.delete(waiter);
          clearTimeout(waiter.timer);
          waiter.resolve(snapshot);
        }
      }
    },
    wait(predicate, label) {
      const previous = history.find(predicate);
      if (previous) return Promise.resolve(previous);
      return new Promise((resolve, reject) => {
        const waiter = { predicate, resolve, timer: undefined };
        waiter.timer = setTimeout(() => {
          waiting.delete(waiter);
          reject(new Error(`${label}: host did not advance C callbacks without a receive`));
        }, 2000);
        waiting.add(waiter);
      });
    },
  };
}

async function changed(probe, field, before, label) {
  const observed = await probe.wait(snapshot => snapshot[field] > before && snapshot.processed > 0, label);
  check(observed.budget > 0 && observed.budget <= 64, 'poll must use a bounded task budget');
  check(observed.afterDestroy === 0, 'module was polled after destroy');
}

export async function exercisePolling(host, probe) {
  try {
    const unary = await host.open(method('Unary'));
    const sends = probe.latest.sends;
    await unary.send(Uint8Array.of(8, 42));
    // No recv/halfClose/host.turn while waiting for this observation. The C
    // unary handler produces its response from on_message, independently.
    await changed(probe, 'sends', sends, 'send-only unary');
    const response = await unary.recv();
    check(response?.[0] === 8 && response[1] === 42, 'send-only unary response');
    check(await unary.recv() === null, 'unary terminal status');
    await unary.close();

    const client = await host.open(method('Client', true));
    const clientSends = probe.latest.sends;
    await client.send(Uint8Array.of(8, 11));
    await changed(probe, 'sends', clientSends, 'client request progress');
    const halves = probe.latest.halves;
    await client.halfClose();
    await changed(probe, 'halves', halves, 'half-close-only progress');
    const total = await client.recv();
    check(total?.[0] === 8 && total[1] === 11, 'client response after half-close');
    check(await client.recv() === null, 'client terminal status');
    await client.close();

    const cancel = await host.open(method('Wait'));
    const cancelSends = probe.latest.sends;
    await cancel.send(new Uint8Array());
    await changed(probe, 'sends', cancelSends, 'waiting handler progress');
    const cancels = probe.latest.cancels;
    cancel.cancel();
    await changed(probe, 'cancels', cancels, 'cancel callback progress');
    await cancel.close();

    const released = await host.open(method('Wait'));
    const releaseSends = probe.latest.sends;
    await released.send(new Uint8Array());
    await changed(probe, 'sends', releaseSends, 'release handler progress');
    const releases = probe.latest.releases;
    await released.close();
    // The last public call has been forgotten. Cancellation/destruction work
    // still queued in the C runtime must drain before another RPC arrives.
    await changed(probe, 'releases', releases, 'release cleanup progress');
  } finally {
    await host.close();
  }
  await probe.wait(snapshot => snapshot.destroyed === 1, 'host destroy');
  const polls = probe.latest.polls;
  await pause(30);
  check(probe.latest.polls === polls && probe.latest.afterDestroy === 0, 'polling continued after host close');
}

export async function directPolling(bytes) {
  const probe = observations();
  const module = observeModule(await instantiateWasm(bytes), snapshot => probe.report(snapshot));
  const host = await createWasmHost(() => module, { capacity: 2 });
  await exercisePolling(host, probe);
}

export async function workerPolling(WorkerConstructor) {
  const worker = new WorkerConstructor(new URL('./polling_worker.mjs', import.meta.url), { type: 'module' });
  const probe = observations();
  const receive = message => {
    if (message?.pollingObservation === 1) probe.report(message.snapshot);
  };
  if (worker.addEventListener) worker.addEventListener('message', event => receive(event.data));
  else worker.on('message', receive);
  const host = new WorkerHost(worker);
  try { await exercisePolling(host, probe); }
  finally { await worker.terminate(); }
}
