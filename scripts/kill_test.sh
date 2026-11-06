#!/usr/bin/env bash
# Kill the durable example while it runs, start it again, and check that the
# thread continued from its last checkpoint instead of starting over.
#
# This is the crash test that a single process cannot do for itself: only the
# loss of the process proves that what survived is on disk.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

moon build src/examples/04-durable-checkpoint --target native > /dev/null

exe="_build/native/debug/build/examples/04-durable-checkpoint/04-durable-checkpoint"
if [ -x "$exe.exe" ]; then
  exe="$exe.exe"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work" 2>/dev/null || true' EXIT

# The answer to compare against: an uninterrupted run.
"$exe" "$work/clean" > "$work/clean.txt"
grep -q "done step=3 log=plan, work, report" "$work/clean.txt" || {
  echo "the uninterrupted run did not finish: $(cat "$work/clean.txt")"
  exit 1
}

# The same work, killed while the slow node is still running.
"$exe" "$work/crashed" > "$work/killed.txt" 2>&1 &
pid=$!
sleep 0.4
kill -9 "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true

if grep -q "done" "$work/killed.txt"; then
  echo "the run finished before it could be killed; raise the sleep in the example"
  exit 1
fi

"$exe" "$work/crashed" > "$work/restarted.txt" 2>&1
grep -q "done step=3 log=plan, work, report" "$work/restarted.txt" || {
  echo "the restarted run did not reach the same state: $(cat "$work/restarted.txt")"
  exit 1
}
if grep -q "plan ran" "$work/restarted.txt"; then
  echo "the restarted run repeated a step that was already checkpointed"
  exit 1
fi

echo "kill test passed: the restarted run continued from its last checkpoint"
