#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/intol-artwork-cache.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/modules" "$project_dir/IntoL/ArtworkCache.swift" \
    "$project_dir/tests/ArtworkCacheTests.swift" -o "$test_dir/artwork-cache-tests"
"$test_dir/artwork-cache-tests"
