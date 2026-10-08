#!/usr/bin/env bash
#
# run_checks.sh
#
# Runs all check suites through the release ChecksRunner executable. SwiftPM
# compiles DumptruckCore once, and the runner executes the 17 suites in order.
#
# Usage: ./run_checks.sh
# Exits nonzero on the first suite that fails to compile or fails at runtime.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

exec swift run -c release ChecksRunner
