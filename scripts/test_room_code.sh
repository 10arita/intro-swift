#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/intol-room-code.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/modules" "$project_dir/IntoL/RoomCode.swift" \
    "$project_dir/tests/RoomCodeTests.swift" -o "$test_dir/room-code-tests"
"$test_dir/room-code-tests"
