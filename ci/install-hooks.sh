#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_DIR="$REPO_ROOT/.git/hooks"

if [ ! -d "$HOOKS_DIR" ]; then
    echo "ERROR: .git/hooks not found. Initialize a git repo first." >&2
    exit 1
fi

HOOK_PATH="$HOOKS_DIR/pre-commit"
cat > "$HOOK_PATH" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$REPO_ROOT/ci/pre-commit.sh"
EOF
chmod +x "$HOOK_PATH"
echo "Installed pre-commit hook to $HOOK_PATH"
