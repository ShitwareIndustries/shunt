#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Running zig fmt --check..."
if ! zig fmt --check "$REPO_ROOT/src" "$REPO_ROOT/tests" 2>&1; then
    echo "FAIL: zig fmt found formatting issues. Run 'zig fmt src/ tests/' to fix." >&2
    exit 1
fi

echo "Running zig build test..."
if ! (cd "$REPO_ROOT" && zig build test) 2>&1; then
    echo "FAIL: zig build test failed" >&2
    exit 1
fi

echo "All pre-commit checks passed."
exit 0
