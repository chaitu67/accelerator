#!/usr/bin/env bash
# Idempotent local environment setup for the accelerator repo.
# Safe to re-run any time: creates what's missing, leaves what's already there alone.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel)"
VENV_DIR="$REPO_ROOT/.venv"

echo "== Python venv =="
if [ ! -d "$VENV_DIR" ]; then
  python3 -m venv "$VENV_DIR"
  echo "created $VENV_DIR"
else
  echo "reusing $VENV_DIR"
fi

"$VENV_DIR/bin/pip" install --upgrade pip --quiet
"$VENV_DIR/bin/pip" install -r "$SKILL_DIR/requirements.txt" --quiet
echo "python: $("$VENV_DIR/bin/python" --version)"
"$VENV_DIR/bin/pip" list --format=freeze

echo
echo "== CLI tools (Homebrew) =="
if ! command -v brew >/dev/null 2>&1; then
  cat <<'EOF'
Homebrew not found. This step installs Terraform, AWS CLI, and the Databricks CLI
via `brew`, and installing Homebrew itself needs sudo, so it isn't done automatically here.

Install it yourself first:
  https://brew.sh

Then re-run this skill to pick up the CLI tools. The Python venv above is already ready to use.
EOF
  exit 0
fi

# Add future CLI tools here: ensure_brew_tool <binary-name> <brew-formula> [tap]
ensure_brew_tool() {
  local binary="$1" formula="$2" tap="${3:-}"
  if command -v "$binary" >/dev/null 2>&1; then
    echo "$binary: already installed ($(command -v "$binary"))"
    return
  fi
  echo "$binary: installing via brew ($formula)"
  [ -n "$tap" ] && brew tap "$tap"
  brew install "$formula"
}

ensure_brew_tool terraform hashicorp/tap/terraform hashicorp/tap
ensure_brew_tool aws awscli
ensure_brew_tool databricks databricks/tap/databricks databricks/tap
ensure_brew_tool gh gh

echo
echo "Local environment ready."
