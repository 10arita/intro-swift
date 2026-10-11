#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/intol-manual-chorus.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/modules" "$project_dir/IntoL/Models.swift" \
    "$project_dir/IntoL/ManualChorusCatalog.swift" "$project_dir/tests/ManualChorusCatalogTests.swift" -o "$test_dir/tests"
"$test_dir/tests" "$project_dir/server/manual-chorus.json"
