#!/usr/bin/env bash
#
# run_checks.sh
#
# Runs all check suites through the release ChecksRunner executable. SwiftPM
# compiles DumptruckCore once, and the runner executes the 18 suites in order.
#
# Usage: ./run_checks.sh
# Exits nonzero on the first suite that fails to compile or fails at runtime.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Checks write presets and reports. Keep them out of the operator's real
# Application Support folder. Not under /var or /tmp: those reach /private
# through a symlink, and the journal's report-path check refuses them.
mkdir -p "$HOME/Library/Caches"
DUMPTRUCK_HOME="$(mktemp -d "$HOME/Library/Caches/dumptruck-checks.XXXXXX")"
export DUMPTRUCK_HOME
trap 'rm -rf "$DUMPTRUCK_HOME"' EXIT
swift run -c release ChecksRunner
