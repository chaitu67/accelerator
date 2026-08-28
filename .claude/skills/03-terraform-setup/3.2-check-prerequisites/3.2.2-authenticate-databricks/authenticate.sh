#!/usr/bin/env bash
# Databricks authentication helper. Only runs steps that don't need
# interactive keyboard input to this script (identity check, browser-based
# OAuth via `databricks auth login`). Falling back to a personal access
# token needs a human to generate it in the workspace UI and type it into
# their own terminal -- never attempted or requested here.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCELERATOR_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel)"
WORKSPACE_ROOT="$(dirname "$ACCELERATOR_ROOT")"
TFVARS="$WORKSPACE_ROOT/databricks/infrastructure/terraform.tfvars"

if ! command -v databricks >/dev/null 2>&1; then
  echo "databricks CLI not installed -> run the 02-setup-local-env skill first." >&2
  exit 1
fi

HOST="${DATABRICKS_HOST:-${TF_VAR_databricks_host:-}}"
if [ -z "$HOST" ] && [ -f "$TFVARS" ]; then
  HOST="$(grep -E '^databricks_host' "$TFVARS" 2>/dev/null | sed -E 's/^databricks_host[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/')"
fi

echo "== Checking Databricks authentication =="
if databricks current-user me >/dev/null 2>&1; then
  echo "Already authenticated."
  databricks current-user me 2>/dev/null | grep -E '"userName"|"user_name"' || true
  exit 0
fi

echo "Not authenticated."
echo

if [ -z "$HOST" ]; then
  cat <<EOF
No Databricks workspace host known yet (checked DATABRICKS_HOST, TF_VAR_databricks_host,
and terraform.tfvars). Re-run this skill with the workspace URL known -- e.g. set
DATABRICKS_HOST=https://<workspace>.cloud.databricks.com first, or fill databricks_host
into databricks/infrastructure/terraform.tfvars (copy from terraform.tfvars.example).
EOF
  exit 1
fi

echo "Attempting browser-based OAuth login (databricks auth login) against $HOST..."
# --profile DEFAULT persists the result to the [DEFAULT] section of
# ~/.databrickscfg, so later commands (and this script's own re-checks)
# authenticate without needing DATABRICKS_HOST set in the environment.
# Without an explicit profile, `databricks auth login` doesn't save
# anything `databricks auth profiles` or plain `current-user me` can find.
if databricks auth login --host "$HOST" --profile DEFAULT; then
  echo "Authenticated."
  databricks current-user me 2>/dev/null || true
  exit 0
fi

cat <<EOF
'databricks auth login' failed, was cancelled, or isn't supported for this workspace.
Fall back to a personal access token:

  1. In the Databricks workspace UI: User Settings > Developer > Access tokens >
     Generate new token.
  2. Run yourself in your own terminal (never paste the token into chat):
       databricks configure --host $HOST --token
     -- or, for Terraform without the CLI profile --
       export TF_VAR_databricks_token=<token>

Then re-run this skill (or 3.2-check-prerequisites) to verify.
EOF
exit 1
