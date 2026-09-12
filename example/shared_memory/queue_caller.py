"""Two bounded queues: synthetic RGB frames -> C detection -> slot returns."""
from __future__ import annotations

import argparse
from collections import deque
import json
import math
from multiprocessing.shared_memory import SharedMemory
from pathlib import Path
import threading
import time

from synurang import ModuleHost
from frame_queue_client import FrameQueueClient
from frame_queue_lite import Frame, FrameEvent, QueueConfig, QueuePolicy, QueueRequest

WIDTH, HEIGHT, BOX, GUARD = 96, 64, 12, 32
PIXELS = WIDTH * HEIGHT * 3
STRIDE = PIXELS + GUARD


def target(frame_id: int) -> tuple[int, int]:
    return (frame_id * 3) % (WIDTH - BOX + 1), (frame_id * 2) % (HEIGHT - BOX + 1)


def has_defect(frame_id: int, scenario: str) -> bool:
    # Adjacent defect frames avoid hiding skipped inspections through a lucky
    # alignment between a periodic defect and the worker's sampling cadence.
    return scenario == "inspection" and frame_id % 7 in (6, 0)


def produce(region: SharedMemory, slot: int, frame_id: int, scenario: str) -> None:
    start = slot * STRIDE
    # Generate directly into the pool, without an image-sized staging object.
    for i in range(PIXELS):
        region.buf[start + i] = 20
    for i in range(PIXELS, STRIDE):
        region.buf[start + i] = 0xCD
    x, y = target(frame_id)
    for row in range(y, y + BOX):
        for col in range(x, x + BOX):
            region.buf[start + (row * WIDTH + col) * 3] = 220
    if has_defect(frame_id, scenario):
        for row in range(y + 5, y + 7):
            for col in range(x + 5, x + 7):
                p = start + (row * WIDTH + col) * 3
                region.buf[p], region.buf[p + 2] = 20, 240


def verify(region: SharedMemory, result, scenario: str) -> None:
    processed = result.event == FrameEvent.PROCESSED
    x, y = target(result.frame_id)
    defect = has_defect(result.frame_id, scenario)
    if processed:
        assert result.detected and (result.x, result.y, result.width, result.height) == (x, y, BOX, BOX)
        assert result.defect == defect
    start = result.slot * STRIDE
    for row in range(HEIGHT):
        for col in range(WIDTH):
            red, green, blue = 20, 20, 20
            if x <= col < x + BOX and y <= row < y + BOX:
                red = 220
                if defect and x + 5 <= col < x + 7 and y + 5 <= row < y + 7:
                    red, blue = 20, 240
                if processed and (col in (x, x + BOX - 1) or row in (y, y + BOX - 1)):
                    red, green, blue = (255 if defect else 0), 255, 0
            p = start + (row * WIDTH + col) * 3
            assert region.buf[p] == red and region.buf[p + 1] == green and region.buf[p + 2] == blue
    assert all(region.buf[start + i] == 0xCD for i in range(PIXELS, STRIDE))


def pool_config(region, *, policy="fifo", slots=16, input_capacity=8, output_capacity=4,
                batch_size=4, batch_wait_ms=50, work_ms=40):
    return QueueConfig(name="/" + region.name.lstrip("/"), width=WIDTH, height=HEIGHT,
                       slot_stride=STRIDE, slot_count=slots, policy=QueuePolicy[policy.upper()],
                       input_capacity=input_capacity, output_capacity=output_capacity,
                       batch_size=batch_size, batch_wait_ms=batch_wait_ms, simulate_work_ms=work_ms)


def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)] if values else 0


def run(build: Path, *, policy="fifo", scenario="tracking", frames=60, fps=60.0,
        work_ms=40, slots=16, input_capacity=8, output_capacity=4, batch_size=4,
        batch_wait_ms=50, consumer_delay_ms=0, output: Path | None = None, quiet=False):
    if not (1 <= frames <= 10000 and 1 <= slots <= 64 and math.isfinite(fps)
            and (fps == 0 or .1 <= fps <= 10000) and 0 <= work_ms <= 1000
            and 0 <= consumer_delay_ms <= 1000):
        raise ValueError("frames=1..10000, slots=1..64, fps=0 or 0.1..10000, delays=0..1000 required")
    if output:
        output.mkdir(parents=True, exist_ok=True)
    region = SharedMemory(create=True, size=slots * STRIDE)
    condition, stop = threading.Condition(), threading.Event()
    available, outstanding, errors = deque(range(slots)), {}, []
    events, latencies = [], []
    started = time.monotonic_ns()
    summary = None
    try:
        # Host teardown precedes pool teardown, including any failed send/recv.
        with ModuleHost.load(build / "backend.so", loader=build / "libsynurang_module_host.so") as host:
            timeout = max(10, frames * ((1 / fps if fps else 0) + (work_ms + consumer_delay_ms + 100) / 1000) + 5)
            with FrameQueueClient(host).run(timeout=timeout) as call:
                config = pool_config(region, policy=policy, slots=slots, input_capacity=input_capacity,
                                     output_capacity=output_capacity, batch_size=batch_size,
                                     batch_wait_ms=batch_wait_ms, work_ms=work_ms)
                call.send(QueueRequest(config=config))
                ready = call.recv()
                assert ready is not None and ready.event == FrameEvent.READY

                def send_frames():
                    next_capture = time.monotonic()
                    try:
                        for frame_id in range(1, frames + 1):
                            if stop.wait(max(0, next_capture - time.monotonic())):
                                return
                            with condition:
                                condition.wait_for(lambda: available or stop.is_set())
                                if stop.is_set():
                                    return
                                slot = available.popleft()
                            captured = time.monotonic_ns()
                            next_capture = time.monotonic() + (1 / fps if fps else 0)
                            produce(region, slot, frame_id, scenario)
                            with condition:
                                outstanding[frame_id] = (slot, captured)
                            call.send(QueueRequest(frame=Frame(slot=slot, frame_id=frame_id, captured_ns=captured)))
                        call.half_close()  # Flush the final, possibly partial batch.
                    except BaseException as error:
                        errors.append(error)
                        stop.set()
                        call.cancel()
                        with condition:
                            condition.notify_all()

                producer = threading.Thread(target=send_frames, name="frame-producer")
                producer.start()
                try:
                    for result in call:
                        received = time.monotonic_ns()
                        if result.event == FrameEvent.SUMMARY:
                            assert summary is None
                            summary = result
                            continue
                        assert summary is None and result.event in (FrameEvent.PROCESSED, FrameEvent.DROPPED)
                        with condition:
                            assert outstanding[result.frame_id] == (result.slot, result.captured_ns)
                        verify(region, result, scenario)
                        if result.event == FrameEvent.PROCESSED:
                            assert result.captured_ns <= result.started_ns <= result.completed_ns <= received
                            latencies.append((received - result.captured_ns) / 1e6)
                            if output and result.frame_id == frames:
                                with (output / f"python_{policy}_{scenario}.ppm").open("wb") as image:
                                    image.write(f"P6\n{WIDTH} {HEIGHT}\n255\n".encode())
                                    view = region.buf[result.slot * STRIDE:result.slot * STRIDE + PIXELS]
                                    try:
                                        image.write(view)
                                    finally:
                                        view.release()
                        events.append(dict(id=result.frame_id, slot=result.slot, status=FrameEvent(result.event).name,
                                           captured_ms=(result.captured_ns - started) / 1e6,
                                           received_ms=(received - started) / 1e6,
                                           completed_ms=(result.completed_ns - started) / 1e6,
                                           batch_id=result.batch_id, batch_size=result.batch_size,
                                           x=result.x, y=result.y, defect=bool(result.defect)))
                        with condition:
                            del outstanding[result.frame_id]
                            available.append(result.slot)
                            condition.notify_all()
                        if consumer_delay_ms:
                            time.sleep(consumer_delay_ms / 1000)
                    producer.join()
                    if errors:
                        raise errors[0]
                    assert summary is not None and not outstanding and len(available) == slots
                    assert len(events) == frames and summary.processed + summary.dropped == frames
                    assert summary.processed == len(latencies)
                    if policy != "latest":
                        assert summary.dropped == 0
                    assert [e["id"] for e in events] == list(range(1, frames + 1))
                finally:
                    stop.set()
                    with condition:
                        condition.notify_all()
                    call.cancel()
                    producer.join()
    finally:
        region.close()
        region.unlink()
    report = dict(caller="Python", policy=policy, scenario=scenario, frames=frames,
                  processed=summary.processed, dropped=summary.dropped, batches=summary.batches,
                  max_batch_size=max(e["batch_size"] for e in events),
                  detected_defects=sum(e["defect"] for e in events),
                  missed_defects=sum(e["status"] == "DROPPED" and has_defect(e["id"], scenario) for e in events),
                  input_high_water=summary.input_high_water, output_high_water=summary.output_high_water,
                  outstanding=0, latency_p50_ms=percentile(latencies, .5),
                  latency_p95_ms=percentile(latencies, .95), events=events)
    if output:
        (output / f"python_{policy}_{scenario}.json").write_text(json.dumps(report, indent=2) + "\n")
    if not quiet:
        print(f"Python {policy:6} {scenario:10}: processed={report['processed']} dropped={report['dropped']} "
              f"latency p50/p95={report['latency_p50_ms']:.1f}/{report['latency_p95_ms']:.1f} ms "
              f"batch<={report['max_batch_size']} defects={report['detected_defects']} "
              f"missed={report['missed_defects']} outstanding=0")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build", type=Path)
    parser.add_argument("--policy", choices=("fifo", "latest", "batch"), default="fifo")
    parser.add_argument("--scenario", choices=("tracking", "inspection"), default="tracking")
    parser.add_argument("--frames", type=int, default=60)
    parser.add_argument("--fps", type=float, default=60, help="Synthetic capture rate; 0 sends as fast as pool permits")
    parser.add_argument("--work-ms", type=int, default=40, help="Simulated per-frame wait; 0 disables it")
    parser.add_argument("--slots", type=int, default=16)
    parser.add_argument("--input-capacity", type=int, default=8)
    parser.add_argument("--output-capacity", type=int, default=4)
    parser.add_argument("--batch-size", type=int, default=4)
    parser.add_argument("--batch-wait-ms", type=int, default=50)
    parser.add_argument("--consumer-delay-ms", type=int, default=0)
    parser.add_argument("--output", type=Path, help="Save metadata JSON and the final annotated PPM")
    arguments = vars(parser.parse_args())
    arguments["build"] = arguments["build"].resolve()
    run(**arguments)
