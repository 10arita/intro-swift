#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/intol-chorus-developer.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -DDEBUG -module-cache-path "$test_dir/modules" \
    "$project_dir/IntoL/ChorusDeveloperData.swift" "$project_dir/IntoL/ChorusWorkbook.swift" \
    "$project_dir/tests/ChorusDeveloperTests.swift" -o "$test_dir/chorus-tests"
"$test_dir/chorus-tests" "$test_dir" "$@"
"${CHORUS_PYTHON:-python3}" "$project_dir/tests/verify_chorus_workbook.py" "$test_dir" "$@"
