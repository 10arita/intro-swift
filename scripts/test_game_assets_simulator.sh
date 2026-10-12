#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
simulator_id=${1:-$(xcrun simctl list devices booted --json | python3 -c '
import json, sys
print(next((d["udid"] for devices in json.load(sys.stdin)["devices"].values()
            for d in devices if d["state"] == "Booted" and d.get("isAvailable")), ""))')}
if [ -z "$simulator_id" ]; then
    echo "Boot an iOS simulator before running this audio-cache test." >&2
    exit 1
fi
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/intol-game-assets.XXXXXX")
server_pid=
cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$test_dir"
}
trap cleanup EXIT
xcrun --sdk iphonesimulator swiftc -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -target "$(uname -m)-apple-ios17.0-simulator" -module-cache-path "$test_dir/modules" \
    "$project_dir/IntoL/Models.swift" "$project_dir/IntoL/ArtworkCache.swift" \
    "$project_dir/IntoL/GameAssets.swift" "$project_dir/tests/GameAssetsTests.swift" \
    -o "$test_dir/game-assets-tests"
node "$project_dir/tests/audio-cache-server.mjs" "$project_dir/server/public/audio/aoi.wav" "$test_dir/port" &
server_pid=$!
attempt=0
while [ ! -s "$test_dir/port" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 50 ] || ! kill -0 "$server_pid" 2>/dev/null; then
        echo "Audio test server failed to start." >&2
        exit 1
    fi
    sleep 0.1
done
xcrun simctl spawn "$simulator_id" "$test_dir/game-assets-tests" "http://127.0.0.1:$(cat "$test_dir/port")/asset.wav"
