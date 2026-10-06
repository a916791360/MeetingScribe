# Learnings


## LRN-20261006-recording-cleanup-order

Status: resolved
Category: best_practice

Stop device capture before reading or saving manifests. A filesystem failure must not bypass recorder cleanup. Exercise this ordering with a recorder spy and a blocked session.json path in an isolated directory.

## LRN-20261006-preparing-ui

Status: resolved
Category: best_practice

A draft marked recording is not proof that device start succeeded. UI must show preparation separately, start elapsed time only after confirmed capture, and distinguish user cancellation from device failure. Lifecycle tests alone missed the visual mismatch; an isolated native UI recorder with delayed start exposed it. Preserve disk failure alerts even in cancellation paths.
