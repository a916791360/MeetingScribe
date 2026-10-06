# Errors


## ERR-20261006-closure-compile

Status: resolved

Warnings-as-errors rejected an unnecessary try around the nonthrowing loadSessions helper in a new lifecycle assertion. Removed try; rerun targeted tests. No real data involved.

## [ERR-20261006-002] XCTest fixture teardown

**Logged**: 2026-10-06
**Priority**: medium
**Status**: resolved
**Area**: tests

### Summary
Foundation waitUntilExit stalled on a Swift cooperative executor after the loopback fixture child had already exited.

### Evidence
Own test process sample points to AuditNetworkTests.Server.stop. Process list shows no remaining fixture child. Interrupted this test runner only; production app left running.

### Resolution
Use terminationHandler plus a bounded semaphore wait, with SIGKILL fallback. Rerun full tests; never count the interrupted run as passing.

### Metadata
- Related Files: Tests/MeetingScribeTests/AuditNetworkTests.swift

## [ERR-20261006-003] Allowed redirect authentication regression

**Logged**: 2026-10-06
**Priority**: high
**Status**: resolved
**Area**: backend

### Summary
Real loopback allowed-origin redirect test found that URLSession strips Authorization even on a relative 307 redirect.

### Resolution
Only after matching scheme, host and effective port, copy original Authorization to the redirect request. Cross-origin status/host/scheme matrix still rejects requests. Final 332 Swift tests pass (one intentional cloud skip).

### Metadata
- Related Files: SummaryEngine.swift, Tests/MeetingScribeTests/AuditNetworkTests.swift

## [ERR-20261006-004] Swift throwing comparison assertion

Status: resolved
Area: tests

The new timing assertion did not compile because an unparenthesized try appeared after >=. Replaced it with XCTAssertGreaterThanOrEqual and a captured pre-confirmation Date. The final focused and full warnings-as-errors test runs passed.


## [ERR-20261006-006] Source archive verification compatibility

**Logged**: 2026-10-06
**Priority**: low
**Status**: resolved
**Area**: infra

### Summary
System Python tarfile lacks the newer extractall(filter=...) argument.

### Resolution
Verify paths of the task-produced Git archive before extracting with the supported API. Regenerate the source delivery against the final local commit and verify the full baseline patch produces that exact tree. The failure affected delivery verification only, not the installed App or data.

## [ERR-20261006-009] Lifecycle fixture and benchmark validation

**Logged**: 2026-10-06
**Priority**: medium
**Status**: resolved
**Area**: tests

### Summary
Initial synthetic fixtures triggered unrelated material gates; benchmark warnings-as-errors rejected an unused transaction result.

### Resolution
Use six adequate synthetic segments and the supported comma glossary format; preserve corrected before-fix cancellation evidence separately. Explicitly discard benchmark transaction results with `_ =`. Final app regression: 350 tests, one cloud skip, no failures. Runtime parity compares fixed input hashes instead of code-signed output parity.

### Metadata
- Related Files: SummaryLifecycleTests.swift, ReviewPersistenceBenchmark.swift, lifecycle/summary-cancel-before-corrected.log

## [ERR-20261006-010] Native startup verification while Mac locked

**Logged**: 2026-10-06
**Priority**: low
**Status**: pending
**Area**: infra

### Summary
After verified 0.11.6 replacement, CUA could not start the installed app because the Mac was locked.

### Evidence
The Mac is locked and automatic unlock could not unlock it.

### Next Action
Retain the installed verified candidate and private rollback backup. Mark native startup and post-launch data verification pending; resume after the user unlocks normally. Do not bypass lock or substitute shell launch for native verification.

## [ERR-20261006-011] Profiler sanitization assertion scope

**Logged**: 2026-10-06
**Priority**: low
**Status**: resolved
**Area**: tests

### Summary
A verification assertion incorrectly rejected the entire target element after its environment and identifiers had already been removed.

### Resolution
Validate absence of environment, UUID and device-name fields rather than the useful synthetic target metadata. Also replace the synthetic app's private temp path with a relative bundle path. The failed assertion ran after successful installed-data comparisons; it did not indicate a data mismatch.
