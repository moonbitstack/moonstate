#!/usr/bin/env bash
# Feed the semantic-conventions registry checker with one traced run.
#
# The traced example exports its spans over OTLP/gRPC. `weaver registry live-check`
# listens on the standard OTLP port, matches every name it receives against the
# registry and writes a report; anything at violation level is a name this library
# made up rather than one the convention defines.
#
# The registry is the GenAI one, because the names on these spans are the GenAI
# ones. Weaver clones it on first use.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
weaver="${WEAVER:-weaver}"
registry="${REGISTRY:-https://github.com/open-telemetry/semantic-conventions-genai.git[model]}"
report="${RUNNER_TEMP:-/tmp}/moonstate-live-check"

rm -rf "$report"
mkdir -p "$report"

"$weaver" registry live-check \
  -r "$registry" \
  --format json \
  --output "$report" \
  --inactivity-timeout 180 \
  --admin-port 4320 \
  > "$report/weaver.log" 2>&1 &
weaver_pid=$!

cleanup() {
  kill "$weaver_pid" 2>/dev/null || true
}
trap cleanup EXIT

for _ in $(seq 1 120); do
  if grep -q "OTLP gRPC listener started" "$report/weaver.log" 2>/dev/null; then
    break
  fi
  sleep 1
done
if ! grep -q "OTLP gRPC listener started" "$report/weaver.log" 2>/dev/null; then
  echo "weaver never opened the OTLP port:"
  tail -30 "$report/weaver.log"
  exit 1
fi

cd "$root"
MOONSTATE_LIVE=1 moon run src/examples/06-traced-run --target native

curl -sf -X POST http://127.0.0.1:4320/shutdown > /dev/null
wait "$weaver_pid" 2>/dev/null || true
trap - EXIT

if [ ! -f "$report/live_check.json" ]; then
  echo "weaver wrote no report:"
  tail -30 "$report/weaver.log"
  exit 1
fi

python3 - "$report/live_check.json" <<'PY'
import collections
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))


def advisories(node):
    if isinstance(node, dict):
        for advice in node.get("all_advice") or []:
            yield advice
        for value in node.values():
            yield from advisories(value)
    elif isinstance(node, list):
        for value in node:
            yield from advisories(value)


counts = collections.Counter(advice["level"] for advice in advisories(report))
violations = counts.get("violation", 0)
spans = report.get("statistics", {}).get("total_entities_by_type", {}).get("span", 0)
print(f"{spans} spans checked: {violations} violations, "
      f"{counts.get('improvement', 0)} improvements")
if violations:
    for advice in advisories(report):
        if advice["level"] == "violation":
            print(f"  {advice['message']}")
    sys.exit("the telemetry does not follow the registry")
PY
