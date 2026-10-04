#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/intol-result-history.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/modules" "$project_dir/IntoL/Models.swift" \
    "$project_dir/IntoL/CloudProfile.swift" "$project_dir/tests/ResultHistoryTests.swift" \
    -o "$test_dir/result-history-tests"
"$test_dir/result-history-tests"
