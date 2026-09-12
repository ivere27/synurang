# Synurang Example App

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Native shared-memory calls

The [shared-memory example](shared_memory/README.md) runs Python and C++ callers
against a C module through the existing call ABI. Protobuf carries the buffer
descriptor and completion; the payload is updated directly in shared memory.
Run it from the repository root with `make test_shared_memory` on Linux.
Its [frame-queue extension](shared_memory/QUEUE.md) adds moving-target detection
and defect inspection with FIFO, Latest and Batch policies. Run
`make test_shared_memory_queue` to compare both callers and open the visual report.
