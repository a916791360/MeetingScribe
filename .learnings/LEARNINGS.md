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
