# Two queues and a shared image pool

Python and C++ continuously generate synthetic RGB frames in shared memory. A C
worker detects a moving red square and draws its bounding box in those same
pages. The caller receives coordinates and ownership notifications through a
second queue. Both callers check every pixel, guard byte, frame ID and slot
return before reusing a buffer.

Two scenarios use the same pipeline:

- **tracking**: follow the moving square. Skipping old frames is useful when
  current position matters more than frame coverage.
- **inspection**: frames 6 and 7 of each seven-frame group contain a blue defect inside the square.
  The backend detects it and draws a yellow border instead of green. Dropping
  that frame means skipping an inspection, which the caller reports separately
  from detected defects.

No camera, OpenCV, model download or additional Python package is required.
Like the [unary example](README.md), this targets Linux. The C module runs inside
the caller process through the existing call ABI; it is not a separate process.

## Run and inspect

```sh
make test_shared_memory_queue
# Equivalent: bash example/shared_memory/run_queue.sh
```

This builds both examples, runs both callers with all three policies and both
scenarios, then runs the queue edge checks. Each demonstration captures 42
frames, aiming for 60 FPS, with a **simulated 40 ms wait per processed frame**.
That intentional overload makes the policy differences visible.

Open `build/shared_memory/queue-results/index.html` locally in a browser. The
standalone report has caller/scenario selectors, playback and a time slider.
Red outlines show the newest captured target; green/yellow boxes show the
latest returned detection. Each policy is measured in its own run, starting at
time zero. The report replays metadata, rather than storing a video.

The directory also contains per-run JSON with every result and a PPM image of
the last annotated frame. The console and report show processed/dropped counts,
capture-to-receive latency p50/p95, actual batch sizes, detected/skipped defects,
and zero outstanding buffers after normal shutdown. These are **pipeline demo
measurements**, including generation, queues, verification-induced backpressure
and configured delays; they are not call-runtime microbenchmarks.

To run one policy with different settings:

```sh
bash example/shared_memory/build.sh
export PYTHONPATH="$PWD/python:$PWD/build/shared_memory"

python3 example/shared_memory/queue_caller.py build/shared_memory \
  --scenario inspection --policy latest --frames 120 --fps 60 --work-ms 40 \
  --output build/shared_memory/queue-results

./build/shared_memory/cpp_queue_caller build/shared_memory \
  --scenario inspection --policy batch --frames 120 --fps 60 --work-ms 40 \
  --batch-size 4 --batch-wait-ms 50 --output build/shared_memory/queue-results

python3 example/shared_memory/queue_report.py build/shared_memory/queue-results
```

Both callers support `--slots`, `--input-capacity`, `--output-capacity`,
`--batch-size`, `--batch-wait-ms` and `--consumer-delay-ms` as well.
Use `--work-ms 0` to disable simulated backend work, `--fps 0` to submit as fast
as the pool permits, or a nonzero consumer delay to demonstrate result-side
backpressure. Saving output is optional for individual runs.

## Queues and policies

```text
caller producer              C module                         caller consumer
fill a free shared slot -> [input descriptor queue]
                                  |
                          FIFO / Latest / Batch
                                  |
                          detect + annotate slot
                                  |
                           [result event queue] -> verify pixels + return slot
            ^_________________________________________________________|
```

Only small Protobuf messages cross `FrameQueue.Run`, one bidirectional call.
The two application queues live in C and contain descriptors/results. A mutex
protects their bounded rings; a condition variable wakes the worker on input,
output capacity, half-close or cancellation. The call runtime also has its own
bounded transport queues. They are additional staging for metadata, so an
application input capacity of eight does not mean only eight sends can succeed.
The buffer pool bounds the total number of outstanding image payloads.

| Policy | When the worker chooses its next work | At capacity / end of input |
| --- | --- | --- |
| FIFO | Take the oldest waiting frame. | Pause input callbacks when full; accepted frames drain in order. |
| Latest | Snapshot the pending input queue; return all but its newest frame as `DROPPED`, then process that newest frame. | A full input queue applies backpressure until selection; frames already being processed remain protected. |
| Batch | Take up to `batch_size` frames together, sharing one batch ID and actual size. | Wait for enough frames or the oldest queued frame's `batch_wait_ms` deadline; half-close flushes a partial batch immediately when the worker is available. |

Latest applies to **frames already admitted to the C input queue**. It cannot
skip descriptors still in the runtime's transport queue, replace an active
frame, or bypass a stalled result consumer. This deliberately keeps both
queues bounded and every buffer return reliable.

Batch selection groups frames, but this C detector still processes them one at
a time, including the simulated wait per frame. Grouping alone does not promise
higher throughput. A future batch-capable inference engine could replace that
loop. The batch deadline limits waiting to assemble work when the worker is
available; it is not an end-to-end latency limit under overload.

Defaults are 16 pool slots, input capacity 8, output capacity 4, batch size 4 and
batch wait 50 ms. Frames are tightly packed 96×64 RGB24 (18,432 bytes), followed
by 32 untouched guard bytes in each slot. The backend accepts dimensions up to
256×256, 1–64 slots/queue entries, and validates the mapped size, stride, policy,
batch limits and IDs before accessing pixels.

The synthetic producer waits for a free slot, so FIFO and Batch preserve all
captured frames while reducing the actual capture rate under load. A real
camera may keep producing outside this pipeline; its own capture/drop policy
must be accounted for separately. Inspection completeness applies to frames
accepted by this example, not unseen events in the physical world.

## Ownership and shutdown

1. Send `QueueConfig` and wait for `READY`. C has opened and mapped the pool.
2. A producer exclusively owns each free slot while filling it. Before sending
   its descriptor, record its slot and strictly increasing frame ID as in flight.
3. C owns submitted slots until their `PROCESSED` or `DROPPED` result returns.
   After publishing either result it never accesses that use of the slot again.
   A processed slot contains the overlay; a dropped slot is unchanged.
4. The consumer validates the result and shared pixels, then returns the slot
   to the producer. Dropped frames must also be consumed and reclaimed. The
   result queue is always reliable FIFO, even with the Latest input policy.
5. Half-close stops submissions. C drains accepted frames, unmaps its pool,
   emits `SUMMARY`, and finishes. The callers verify one return per submitted
   frame and zero outstanding slots before closing and unlinking shared memory.

On a protocol error, deadline or cancellation, completion messages may be
unavailable. Stop the caller's producer and **close the host before reclaiming
outstanding slots or unmapping/unlinking the pool**. A terminal error or local
call close alone is not permission to reuse those slots.

The C worker retains its stream through all pixel access and unmapping. Its
simulated work wait is interruptible; actual scanning is bounded to one small
frame. One persistent worker is started lazily per instance, with one active
queue session at a time. Sequential sessions reuse it; independent instances
can run concurrently. Ordinary unary calls remain available during queue work.
The registration owns and joins the worker at instance destruction, before the
module can unload. This also covers its execution after the final stream release.

All idle waits use notifications. Timers are used only for requested frame
pacing, batch assembly, simulated work and optional slow consumption. There is
no 1 ms polling loop added by this example. The call ABI and version remain
unchanged; payload zero-copy concerns these CPU mappings. Metadata encoding,
optional file output and GPU/camera buffer acquisition have separate costs.

## Validation

The runnable callers verify bounding boxes, defect flags, all modified and
unmodified pixels, guards, ordered unique slot returns and final accounting.
`test/call/frame_queue_edges.py` additionally checks tiny pool/queue limits,
Latest drop reclamation, full/partial/timed-out batches, bounded result
backpressure, cancellation while results are blocked, an unrelated unary call
during slow queue work, invalid configuration/descriptors, busy-slot rejection,
sequential sessions and removal of the backend mapping before pool teardown.
