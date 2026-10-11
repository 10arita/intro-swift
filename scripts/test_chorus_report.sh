#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/intol-chorus-report.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/modules" "$project_dir/IntoL/Models.swift" \
    "$project_dir/IntoL/RevealAudioPlayback.swift" "$project_dir/IntoL/ChorusReport.swift" \
    "$project_dir/tests/RoomServiceTestSupport.swift" "$project_dir/tests/ChorusReportTests.swift" \
    -o "$test_dir/chorus-report-tests"
"$test_dir/chorus-report-tests"
