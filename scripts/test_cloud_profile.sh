#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/intol-cloud-profile.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/modules" "$project_dir/IntoL/Models.swift" "$project_dir/IntoL/RankMeasurement.swift" "$project_dir/IntoL/CloudProfile.swift" \
    "$project_dir/tests/CloudProfileTests.swift" -o "$test_dir/cloud-profile-tests"
"$test_dir/cloud-profile-tests"
