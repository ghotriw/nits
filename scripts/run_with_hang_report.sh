#!/usr/bin/env bash
# Runs a command (the tests); if it is still running after HANG_SECONDS, prints the stacks of the test process's
# threads (`sample`) and what the machine is doing, then kills it and fails. A hung run otherwise leaves a log that
# only says that nothing finished, not what the threads were waiting for.
#
# Usage: HANG_SECONDS=240 scripts/run_with_hang_report.sh swift test ...
set -uo pipefail

limit="${HANG_SECONDS:-240}"

"$@" &
pid=$!

elapsed=0
while kill -0 "$pid" 2>/dev/null; do
    if ((elapsed >= limit)); then
        echo "::error::No end after ${limit} s: sampling the test process, then stopping it"
        echo "cpus: $(sysctl -n hw.ncpu 2>/dev/null)  load: $(sysctl -n vm.loadavg 2>/dev/null)"
        ps -Ao pid,pcpu,rss,etime,comm -r | head -15
        for helper in $(pgrep -x swiftpm-testing-helper; pgrep -f 'NitsPackageTests.xctest'); do
            out="${TMPDIR:-/tmp}/hang-sample-${helper}.txt"
            echo "::group::sample of $helper"
            sample "$helper" 5 -file "$out" >/dev/null 2>&1
            cat "$out" 2>/dev/null
            echo "::endgroup::"
        done
        pkill -P "$pid" 2>/dev/null
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        exit 124
    fi
    sleep 5
    elapsed=$((elapsed + 5))
done

wait "$pid"
