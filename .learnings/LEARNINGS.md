# Learnings


## LRN-20261006-recording-cleanup-order

Status: resolved
Category: best_practice

Stop device capture before reading or saving manifests. A filesystem failure must not bypass recorder cleanup. Exercise this ordering with a recorder spy and a blocked session.json path in an isolated directory.
