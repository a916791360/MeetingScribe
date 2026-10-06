# Learnings


## LRN-20261006-recording-cleanup-order

Status: resolved
Category: best_practice

Stop device capture before reading or saving manifests. A filesystem failure must not bypass recorder cleanup. Exercise this ordering with a recorder spy and a blocked session.json path in an isolated directory.

## LRN-20261006-preparing-ui

Status: resolved
Category: best_practice

A draft marked recording is not proof that device start succeeded. UI must show preparation separately, start elapsed time only after confirmed capture, and distinguish user cancellation from device failure. Lifecycle tests alone missed the visual mismatch; an isolated native UI recorder with delayed start exposed it. Preserve disk failure alerts even in cancellation paths.


## [LRN-20261006-005] best_practice

**Logged**: 2026-10-06
**Priority**: medium
**Status**: resolved
**Area**: tests

### Summary
Checkpoint fixtures must model automatic CPU fallback and persisted date precision.

### Details
A single failing CLI invocation is not a durable chunk failure because the runner retries on CPU. Use an explicit release marker to keep both attempts failing until simulated recovery. Compare decoded saved baselines when ISO8601 serializes dates to seconds. Record input versus relocated/signed runtime hashes separately; generate provenance after child signing and avoid outer deep re-signing afterward.

### Metadata
- Source: error
- Related Files: AuditRecordingPipelineTests.swift, CheckpointRepositoryTests.swift, Scripts/package_app.sh

## [LRN-20261006-007] best_practice

**Logged**: 2026-10-06
**Priority**: high
**Status**: resolved
**Area**: backend

### Summary
Cancellation requests do not release operation ownership; background commits also need ordered UI publication.

### Details
Keep the task slot until the original analysis exits, including cancellation cleanup. Deletion needs a separate gate across awaiting the task and removing files. Atomic read-modify-write protects disk data but does not stop an older returned snapshot from reaching MainActor after a newer rename. Carry a monotonic transaction revision and reject older publication. Test this through the actual publication entry point and a continuation-controlled analyzer. Keep sufficient synthetic material to avoid unrelated migration gates, and use the supported comma-separated glossary syntax.

### Metadata
- Source: error
- Related Files: MeetingStore.swift, SessionStorage.swift, SummaryLifecycleTests.swift, CheckpointRepositoryTests.swift
- Pattern-Key: harden.async_operation_publication

## [LRN-20261006-008] best_practice

**Logged**: 2026-10-06
**Priority**: medium
**Status**: resolved
**Area**: infra

### Summary
Compare fixed runtime inputs separately from code-signed bytes; sanitize profiler artifacts before sharing.

### Details
New signing can change Mach-O bytes even when inputs are identical. Verify fixed input SHA, each new signed output against provenance, and smoke-test the actual candidate. Instruments traces and TOC can contain process environment and device identifiers; publish only sanitized schema/aggregates, retain raw traces in ignored local output. Tick gaps measure actor scheduling, not FPS; consecutive synchronous transactions must not be described as one transaction.

### Metadata
- Source: error
- Related Files: docs/reviews/2026-10-06/lifecycle/runtime-smoke.py, ReviewPersistenceBenchmark.swift, ui-observations.md
