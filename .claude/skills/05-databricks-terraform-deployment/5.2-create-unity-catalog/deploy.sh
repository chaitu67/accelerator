#!/usr/bin/env bash
# Deploys the Unity Catalog resources scaffolded by implement.sh.
#
# Two explicit steps, never combined into one unattended apply:
#   deploy.sh plan   (default) -- terraform init + plan, saves ./tfplan for review
#   deploy.sh apply             -- applies exactly the reviewed ./tfplan
#
# Unlike 5.1-create-workspace's deploy.sh, this does NOT do an account-level
# Databricks OAuth login -- catalogs/schemas/storage credentials are
# workspace-scoped (Unity Catalog REST API on one workspace), so ordinary
# workspace-level auth (3.2.2-authenticate-databricks) is all that's needed.
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

if [ ! -f "$INFRA_DIR/modules/catalog/main.tf" ]; then
  echo "modules/catalog/main.tf not found in $INFRA_DIR -> run implement.sh in this skill first." >&2
  exit 1
fi
if [ ! -f "$INFRA_DIR/catalogs.auto.tfvars" ]; then
  echo "catalogs.auto.tfvars not found -> add at least one catalog entry first (see SKILL.md Phase 1)." >&2
  exit 1
fi

echo "== Checking workspace-level Databricks authentication =="
if ! databricks current-user me >/dev/null 2>&1; then
  echo "Not authenticated (or the configured profile/host can't reach the target workspace)." >&2
  echo "Run the 3.2.2-authenticate-databricks skill, and confirm databricks_host/databricks_profile" >&2
  echo "in terraform.tfvars actually point at the workspace you want these catalogs created in." >&2
  exit 1
fi
echo "Authenticated."

# Check every catalog's bucket_name (catalogs.auto.tfvars can define more than one).
BUCKETS="$(grep -oE 'bucket_name[[:space:]]*=[[:space:]]*"[^"]+"' "$INFRA_DIR/catalogs.auto.tfvars" 2>/dev/null \
  | sed -E 's/^bucket_name[[:space:]]*=[[:space:]]*"([^"]+)"$/\1/')"
for BUCKET in $BUCKETS; do
  if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    echo
    echo "WARNING: S3 bucket '$BUCKET' already exists and is reachable with your AWS credentials." >&2
    echo "S3 bucket names are globally unique across ALL AWS accounts -- if apply fails with a" >&2
    echo "'BucketAlreadyExists' error, pick a different bucket_name value for that catalog." >&2
  fi
done

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
  else
    echo
    echo "terraform apply failed (see errors above). Any resources it did create are safely" >&2
    echo "recorded in Terraform state (check 'terraform state list') -- nothing needs to be" >&2
    echo "recreated. The saved plan is now stale (state changed); re-run 'deploy.sh plan' to" >&2
    echo "see what's left, review it, then 'deploy.sh apply' again." >&2
    exit "$APPLY_STATUS"
  fi
fi
