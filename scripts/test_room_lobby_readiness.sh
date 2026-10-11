#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/intol-room-lobby.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/modules" "$project_dir/IntoL/Models.swift" \
    "$project_dir/IntoL/RoomService.swift" "$project_dir/tests/RoomServiceTestSupport.swift" \
    "$project_dir/tests/RoomLobbyReadinessTests.swift" -o "$test_dir/room-lobby-tests"
"$test_dir/room-lobby-tests"
