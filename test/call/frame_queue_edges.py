"""Policy, backpressure, and asynchronous pool-lifetime checks (Linux)."""
from contextlib import contextmanager
from multiprocessing.shared_memory import SharedMemory
from pathlib import Path
import sys
import threading
import time
import unittest

from synurang import FfiError, ModuleHost
from frame_queue_client import FrameQueueClient
from frame_queue_lite import Frame, FrameEvent, QueueRequest
from shared_memory_client import SharedMemoryClient
from shared_memory_lite import BufferRequest

BUILD = Path(sys.argv.pop(1)).resolve()
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "example/shared_memory"))
from queue_caller import STRIDE, pool_config, produce, run, verify  # noqa: E402


class FrameQueueTests(unittest.TestCase):
    @contextmanager
    def session(self, **changes):
        slots = changes.pop("slots", 16)
        region = SharedMemory(create=True, size=slots * STRIDE)
        try:
            with ModuleHost.load(BUILD / "backend.so", loader=BUILD / "libsynurang_module_host.so") as host:
                with FrameQueueClient(host).run(timeout=10) as call:
                    call.send(QueueRequest(config=pool_config(region, slots=slots, **changes)))
                    self.assertEqual(call.recv().event, FrameEvent.READY)
                    yield region, host, call
                host.close()
            self.assertEqual(Path("/proc/self/maps").read_text().count(region.name), 1)
        finally:
            region.close()
            region.unlink()

    def send(self, call, slot, frame_id):
        call.send(QueueRequest(frame=Frame(slot=slot, frame_id=frame_id, captured_ns=time.monotonic_ns())))

    def test_lossless_fifo_small_pool_and_latest_releases_dropped_slots(self):
        fifo = run(BUILD, frames=21, fps=0, work_ms=0, slots=2,
                   input_capacity=1, output_capacity=1, scenario="inspection", quiet=True)
        self.assertEqual((fifo["processed"], fifo["dropped"], fifo["detected_defects"]), (21, 0, 6))
        self.assertEqual((fifo["input_high_water"], fifo["output_high_water"]), (1, 1))
        latest = run(BUILD, policy="latest", frames=35, fps=0, work_ms=40,
                     slots=8, input_capacity=8, output_capacity=1, scenario="inspection", quiet=True)
        self.assertGreater(latest["dropped"], 0)
        self.assertEqual(latest["detected_defects"] + latest["missed_defects"], 10)
        self.assertEqual(latest["events"][-1]["status"], "PROCESSED")
        self.assertEqual(latest["outstanding"], 0)

    def test_full_batches_and_partial_batch_at_eof(self):
        report = run(BUILD, policy="batch", frames=9, fps=0, work_ms=0, batch_size=4,
                     batch_wait_ms=1000, scenario="inspection", quiet=True)
        self.assertEqual([e["batch_size"] for e in report["events"]], [4] * 8 + [1])
        self.assertEqual(report["batches"], 3)
        self.assertEqual((report["processed"], report["detected_defects"]), (9, 2))

    def test_batch_timeout_flushes_without_half_close(self):
        with self.session(policy="batch", batch_size=4, batch_wait_ms=60, work_ms=0) as (region, _, call):
            produce(region, 0, 1, "tracking")
            before = time.monotonic()
            self.send(call, 0, 1)
            result = call.recv()  # Request side deliberately remains open.
            self.assertGreaterEqual(time.monotonic() - before, .045)
            self.assertEqual((result.event, result.batch_size), (FrameEvent.PROCESSED, 1))
            verify(region, result, "tracking")
            call.half_close()
            self.assertEqual(call.recv().event, FrameEvent.SUMMARY)
            self.assertIsNone(call.recv())

    def test_result_backpressure_is_bounded_and_lossless(self):
        with self.session(slots=64, input_capacity=2, output_capacity=2, work_ms=0) as (region, _, call):
            for slot in range(64):
                produce(region, slot, slot + 1, "inspection")
            sent, errors = threading.Event(), []

            def send_all():
                try:
                    for slot in range(64):
                        self.send(call, slot, slot + 1)
                    call.half_close()
                    sent.set()
                except Exception as error:
                    errors.append(error)

            sender = threading.Thread(target=send_all)
            sender.start()
            try:
                # With no consumer, 64 descriptors cannot fit in the bounded
                # application + transport queues. send must eventually wait.
                self.assertFalse(sent.wait(.15))
                results = []
                for result in call:
                    if result.event == FrameEvent.SUMMARY:
                        self.assertEqual((result.input_high_water, result.output_high_water), (2, 2))
                    else:
                        verify(region, result, "inspection")
                        results.append(result.frame_id)
                self.assertEqual(results, list(range(1, 65)))
            finally:
                call.cancel()
                sender.join(5)
            self.assertFalse(sender.is_alive())
            self.assertFalse(errors)
            self.assertTrue(sent.is_set())

    def test_cancel_while_results_are_blocked_unmaps_and_joins(self):
        with self.session(slots=32, input_capacity=32, output_capacity=1, work_ms=0) as (region, host, call):
            for slot in range(32):
                produce(region, slot, slot + 1, "tracking")
                self.send(call, slot, slot + 1)
            time.sleep(.05)  # Allow the bounded result queues to fill; no recv.
            call.close()  # No completion is needed for host teardown to work.
            host.close()
            self.assertEqual(Path("/proc/self/maps").read_text().count(region.name), 1)
            before = bytes(region.buf)
            time.sleep(.03)
            self.assertEqual(bytes(region.buf), before)

    def test_slow_worker_does_not_block_unary_or_cancel(self):
        with self.session(work_ms=1000) as (region, host, call):
            produce(region, 0, 1, "tracking")
            self.send(call, 0, 1)
            # A different slot is still caller-owned. Existing unary callbacks
            # remain runnable while the queue worker waits on the first slot.
            request = BufferRequest(name="/" + region.name, offset=STRIDE, length=16, xor_mask=1, request_id=1)
            started = time.monotonic()
            done = SharedMemoryClient(host).process(request, timeout=.5)
            self.assertEqual(done.bytes_processed, 16)
            call.cancel()
            host.close()
            self.assertLess(time.monotonic() - started, .8)

    def test_reusing_a_busy_slot_fails_before_modifying_it(self):
        with self.session(work_ms=1000) as (region, host, call):
            produce(region, 0, 1, "tracking")
            before = bytes(region.buf)
            self.send(call, 0, 1)
            self.send(call, 0, 2)
            with self.assertRaises(FfiError) as caught:
                call.recv()
            self.assertEqual(caught.exception.grpc_code, 3)
            host.close()
            self.assertEqual(bytes(region.buf), before)

    def test_bad_configurations_and_request_order(self):
        region = SharedMemory(create=True, size=16 * STRIDE)
        try:
            for changes in (dict(name="/bad/name"), dict(name="/bad\x00name"), dict(width=0),
                            dict(width=257), dict(slot_stride=1), dict(slot_count=17),
                            dict(policy=99), dict(input_capacity=0), dict(output_capacity=65),
                            dict(policy=3, batch_size=9), dict(policy=3, batch_wait_ms=0)):
                with self.subTest(changes=changes):
                    with ModuleHost.load(BUILD / "backend.so", loader=BUILD / "libsynurang_module_host.so") as host:
                        with FrameQueueClient(host).run(timeout=5) as call:
                            config = pool_config(region)
                            for key, value in changes.items():
                                setattr(config, key, value)
                            call.send(QueueRequest(config=config))
                            with self.assertRaises(FfiError) as caught:
                                call.recv()
                            self.assertEqual(caught.exception.grpc_code, 11 if changes == dict(slot_count=17) else 3)
            for payload in (b"", b"\x12\x05x", QueueRequest(frame=Frame(frame_id=1)).to_bytes()):
                with ModuleHost.load(BUILD / "backend.so", loader=BUILD / "libsynurang_module_host.so") as host:
                    with host.open("/synurang.example.shm.FrameQueue/Run", request_stream=True, response_stream=True, timeout=5) as call:
                        call.send(payload)
                        with self.assertRaises(FfiError) as caught:
                            call.recv()
                        self.assertEqual(caught.exception.grpc_code, 3)
        finally:
            region.close()
            region.unlink()

    def test_empty_stream_and_sequential_sessions_on_same_instance(self):
        with self.session(work_ms=0) as (region, host, call):
            call.half_close()
            self.assertEqual(call.recv().event, FrameEvent.SUMMARY)
            self.assertIsNone(call.recv())
            for _ in range(3):
                with FrameQueueClient(host).run(timeout=5) as another:
                    another.send(QueueRequest(config=pool_config(region, work_ms=0)))
                    self.assertEqual(another.recv().event, FrameEvent.READY)
                    produce(region, 0, 1, "tracking")
                    self.send(another, 0, 1)
                    another.half_close()
                    verify(region, another.recv(), "tracking")
                    self.assertEqual(another.recv().event, FrameEvent.SUMMARY)
                    self.assertIsNone(another.recv())


if __name__ == "__main__":
    unittest.main(verbosity=2)
