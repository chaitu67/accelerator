#!/usr/bin/env bash
# Deploys the new-workspace resources scaffolded by implement.sh.
#
# Two explicit steps, never combined into one unattended apply:
#   deploy.sh plan   (default) -- terraform init + plan, saves ./tfplan for review
#   deploy.sh apply             -- applies exactly the reviewed ./tfplan
#
# Also checks/triggers ACCOUNT-LEVEL Databricks auth (distinct from the
# workspace-level auth 3.2.2-authenticate-databricks sets up) -- creating a
# workspace is an account-admin operation against accounts.cloud.databricks.com.
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

for bin in terraform databricks aws; do
  command -v "$bin" >/dev/null 2>&1 || { echo "$bin not on PATH -> run the 02-setup-local-env skill first." >&2; exit 1; }
done

if [ ! -f "$INFRA_DIR/workspace.tf" ]; then
  echo "workspace.tf not found in $INFRA_DIR -> run implement.sh in this skill first." >&2
  exit 1
fi
if [ ! -f "$INFRA_DIR/terraform.tfvars" ]; then
  echo "terraform.tfvars not found -> fill in the new_workspace_*/databricks_account_* variables first (see terraform.tfvars.example)." >&2
  exit 1
fi

tfvar() {
  grep -E "^$1" "$INFRA_DIR/terraform.tfvars" 2>/dev/null | sed -E "s/^$1[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/"
}

ACCOUNT_ID="$(tfvar databricks_account_id)"
ACCOUNT_PROFILE="$(tfvar databricks_account_profile)"
[ -z "$ACCOUNT_PROFILE" ] && ACCOUNT_PROFILE="ACCOUNT"

if [ -z "$ACCOUNT_ID" ]; then
  echo "databricks_account_id is not set in terraform.tfvars -> get it from the Account Console (top right) and set it first." >&2
  exit 1
fi

echo "== Checking account-level Databricks authentication (profile: $ACCOUNT_PROFILE) =="
PROFILES_JSON="$(databricks auth profiles -o json 2>/dev/null || true)"
ALREADY_VALID="$(echo "$PROFILES_JSON" | grep -A3 "\"name\": *\"$ACCOUNT_PROFILE\"" | grep -o '"valid": *true' || true)"

if [ -n "$ALREADY_VALID" ]; then
  echo "Already authenticated."
else
  echo "Not authenticated. Opening browser for account-level OAuth login..."
  echo "(This must be done by an ACCOUNT ADMIN, not just a workspace admin/user.)"
  if ! databricks auth login --host "https://accounts.cloud.databricks.com" --account-id "$ACCOUNT_ID" --profile "$ACCOUNT_PROFILE"; then
    echo "Account-level login failed or was cancelled." >&2
    exit 1
  fi
fi

BUCKET="$(tfvar new_workspace_root_bucket)"
if [ -n "$BUCKET" ] && aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  echo
  echo "WARNING: S3 bucket '$BUCKET' already exists and is reachable with your AWS credentials." >&2
  echo "S3 bucket names are globally unique across ALL AWS accounts -- if apply fails with a" >&2
  echo "'BucketAlreadyExists' error, pick a different new_workspace_root_bucket value." >&2
fi

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
  echo "Plan saved to $INFRA_DIR/tfplan. Review the resources above -- this creates real,"
  echo "billed AWS + Databricks infrastructure. Once you're ready, run:"
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
    echo
    echo "Workspace creation can take several minutes after apply reports success --" \
         "check new_workspace_status above, or the Account Console, until it's RUNNING."
  else
    echo
    echo "terraform apply failed (see errors above). Any resources it did create are safely" >&2
    echo "recorded in Terraform state (check 'terraform state list') -- nothing needs to be" >&2
    echo "recreated. The saved plan is now stale (state changed); re-run 'deploy.sh plan' to" >&2
    echo "see what's left, review it, then 'deploy.sh apply' again." >&2
    exit "$APPLY_STATUS"
  fi
fi
