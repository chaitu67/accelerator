#!/usr/bin/env bash
# Deploys the Unity Catalog volume resources scaffolded by implement.sh.
#
# Two explicit steps, never combined into one unattended apply:
#   deploy.sh plan   (default) -- terraform init + plan, saves ./tfplan for review
#   deploy.sh apply             -- applies exactly the reviewed ./tfplan
#
# Same as 5.2-create-unity-catalog's deploy.sh: no account-level Databricks OAuth
# login -- volumes are workspace-scoped (Unity Catalog REST API on one
# workspace), so ordinary workspace-level auth (3.2.2-authenticate-databricks)
# is all that's needed.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCELERATOR_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel)"
WORKSPACE_ROOT="$(dirname "$ACCELERATOR_ROOT")"
INFRA_DIR="$WORKSPACE_ROOT/databricks/infrastructure"
ACTION="${1:-plan}"

if [ "$ACTION" != "plan" ] && [ "$ACTION" != "apply" ]; then
  echo "Usage: deploy.sh [plan|apply]  (default: plan)" >&2
  exit 1
fi

for bin in terraform databricks; do
  command -v "$bin" >/dev/null 2>&1 || { echo "$bin not on PATH -> run the 02-setup-local-env skill first." >&2; exit 1; }
done

if [ ! -f "$INFRA_DIR/modules/volume/main.tf" ]; then
  echo "modules/volume/main.tf not found in $INFRA_DIR -> run implement.sh in this skill first." >&2
  exit 1
fi
if [ ! -f "$INFRA_DIR/volumes.auto.tfvars" ]; then
  echo "volumes.auto.tfvars not found -> add at least one volume entry first (see SKILL.md Phase 1)." >&2
  exit 1
fi

# Same rationale as 5.2's deploy.sh: check auth against the SAME profile
# Terraform's default provider actually uses (from the gitignored
# terraform.tfvars), not whatever profile the bare `databricks` CLI would
# otherwise resolve on its own.
WORKSPACE_PROFILE="$(grep -hE '^databricks_profile' "$INFRA_DIR/terraform.tfvars" 2>/dev/null \
  | head -1 | sed -E 's/^databricks_profile[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/')"
[ -z "$WORKSPACE_PROFILE" ] && WORKSPACE_PROFILE="DEFAULT"

echo "== Checking workspace-level Databricks authentication (profile: $WORKSPACE_PROFILE) =="
if ! databricks current-user me --profile "$WORKSPACE_PROFILE" >/dev/null 2>&1; then
  echo "Not authenticated (or the configured profile/host can't reach the target workspace)." >&2
  echo "Run the 3.2.2-authenticate-databricks skill, and confirm databricks_host/databricks_profile" >&2
  echo "in terraform.tfvars actually point at the workspace you want these volumes created in." >&2
  exit 1
fi
echo "Authenticated."

cd "$INFRA_DIR"
echo
echo "== terraform init =="
if ! terraform init -input=false; then
  echo
  echo "terraform init failed (see errors above) -- fix the configuration and re-run." >&2
  exit 1
fi

if [ "$ACTION" = "plan" ]; then
  echo
  echo "== terraform plan =="
  if ! terraform plan -input=false -out=tfplan; then
    echo
    echo "terraform plan failed (see errors above) -- nothing saved, nothing to apply." >&2
    exit 1
  fi
  echo
  echo "Plan saved to $INFRA_DIR/tfplan. Review the resources above -- this creates real"
  echo "Databricks Unity Catalog volumes. Once you're ready, run:"
  echo "  bash $SKILL_DIR/deploy.sh apply"
else
  if [ ! -f tfplan ]; then
    echo "No saved plan at $INFRA_DIR/tfplan -> run 'deploy.sh plan' first and review it before applying." >&2
    exit 1
  fi
  echo
  echo "== terraform apply (from reviewed plan) =="
  terraform apply -input=false tfplan
  APPLY_STATUS=$?
  rm -f tfplan

  if [ "$APPLY_STATUS" -eq 0 ]; then
    echo
    echo "== Outputs =="
    terraform output
  else
    echo
    echo "terraform apply failed (see errors above). Any resources it did create are safely" >&2
    echo "recorded in Terraform state (check 'terraform state list') -- nothing needs to be" >&2
    echo "recreated. The saved plan is now stale (state changed); re-run 'deploy.sh plan' to" >&2
    echo "see what's left, review it, then 'deploy.sh apply' again." >&2
    exit "$APPLY_STATUS"
  fi
fi
