#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/intol-playlist-preparation.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/modules" "$project_dir/IntoL/Models.swift" \
    "$project_dir/IntoL/PlaylistPreparation.swift" "$project_dir/tests/PlaylistPreparationTests.swift" \
    -o "$test_dir/playlist-preparation-tests"
"$test_dir/playlist-preparation-tests"
