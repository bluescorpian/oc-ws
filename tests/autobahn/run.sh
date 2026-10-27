#!/usr/bin/env bash
# Runs the Autobahn WebSocket conformance suite against oc-ws on the host
# (desktop Lua 5.3 with LuaSocket standing in for the internet card).
#
# Excluded: 9.* (throughput with multi-megabyte messages; slow in pure Lua and
# irrelevant at OpenComputers memory sizes) and 12.*/13.* (permessage-deflate,
# which oc-ws does not offer).
#
# Usage: tests/autobahn/run.sh   (from the repo root, inside `nix develop`)
set -euo pipefail

cd "$(dirname "$0")/../.."
reports="$PWD/tests/autobahn/reports"
rm -rf "$reports"
mkdir -p "$reports"

image=crossbario/autobahn-testsuite:25.10.1
container=$(docker run -d --rm --network host \
	-v "$PWD/tests/autobahn:/config:ro" -v "$reports:/reports" \
	"$image" wstest -m fuzzingserver -s /config/fuzzingserver.json)
trap 'docker stop "$container" >/dev/null' EXIT

for _ in $(seq 60); do
	if (echo >/dev/tcp/127.0.0.1/9001) 2>/dev/null; then break; fi
	sleep 1
done

lua tests/autobahn/client.lua

index="$reports/clients/index.json"
jq -r '.["oc-ws"] | to_entries[] | "\(.key) \(.value.behavior) \(.value.behaviorClose)"' "$index" |
	sort -V >"$reports/summary.txt"
echo "behavior counts:"
awk '{print $2}' "$reports/summary.txt" | sort | uniq -c
failed=$(awk '$2 == "FAILED" || $3 == "FAILED"' "$reports/summary.txt")
if [ -n "$failed" ]; then
	echo "failed cases:"
	echo "$failed"
	exit 1
fi
echo "all cases passed (full report: $reports/clients/index.html)"
