#!/usr/bin/env bash
#
# Runs the unit test suite (37 tests, no network, no gh binary needed).
#
#   ./test.sh                    # run everything
#   ./test.sh --filter PRSection # run a subset
#
# XCTest ships with a full Xcode install, not the Command Line Tools. If the
# active developer directory is the CLT, `swift test` fails with
# "no such module 'XCTest'". This script detects Xcode.app and points SwiftPM
# at it automatically.
#
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v swift >/dev/null 2>&1; then
	echo "error: 'swift' not found. Install the Command Line Tools:" >&2
	echo "         xcode-select --install" >&2
	exit 1
fi

XCODE_XCTEST="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework"

if [[ -d "${XCODE_XCTEST}" ]]; then
	# Respect an explicit DEVELOPER_DIR set by the caller.
	export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi

echo "==> swift test (DEVELOPER_DIR=${DEVELOPER_DIR:-<active toolchain>})"
swift test "$@"
