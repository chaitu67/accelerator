#!/usr/bin/env bash
# Points backend.tf at a remote S3 backend and migrates existing local state
# into it via `terraform init -migrate-state`. Refuses to overwrite an
# already-active backend block, and never suppresses the migrate confirmation
# prompt -- the user sees exactly what terraform is about to do.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCELERATOR_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel)"
WORKSPACE_ROOT="$(dirname "$ACCELERATOR_ROOT")"
INFRA_DIR="$WORKSPACE_ROOT/databricks/infrastructure"
BACKEND_FILE="$INFRA_DIR/backend.tf"

BUCKET="${1:-}"
REGION="${2:-}"
TABLE="${3:-}" # optional -- omit to use S3-native locking (use_lockfile) instead

if [ -z "$BUCKET" ] || [ -z "$REGION" ]; then
  echo "Usage: migrate.sh <bucket-name> <region> [lock-table-name]" >&2
  exit 1
fi

if [ ! -d "$INFRA_DIR" ]; then
  echo "Error: infrastructure/ not found at $INFRA_DIR -> run 3.1-scaffold-infrastructure first." >&2
  exit 1
fi

if [ -f "$BACKEND_FILE" ] && grep -qE '^\s*backend\s+"s3"\s*\{' "$BACKEND_FILE" 2>/dev/null; then
  echo "Error: $BACKEND_FILE already has an active S3 backend block:" >&2
  echo >&2
  grep -A6 -E '^\s*backend\s+"s3"\s*\{' "$BACKEND_FILE" >&2
  echo >&2
  echo "Refusing to overwrite it automatically -- confirm with the user whether to repoint" >&2
  echo "it at bucket '$BUCKET'${TABLE:+ / table '$TABLE'}, then edit backend.tf by hand if so." >&2
  exit 1
fi

echo "== Writing remote backend config to $BACKEND_FILE =="
if [ -n "$TABLE" ]; then
  cat > "$BACKEND_FILE" <<EOF
terraform {
  backend "s3" {
    bucket         = "$BUCKET"
    key            = "databricks/infrastructure/terraform.tfstate"
    region         = "$REGION"
    dynamodb_table = "$TABLE"
    encrypt        = true
  }
}
EOF
else
  cat > "$BACKEND_FILE" <<EOF
terraform {
  backend "s3" {
    bucket       = "$BUCKET"
    key          = "databricks/infrastructure/terraform.tfstate"
    region       = "$REGION"
    use_lockfile = true # S3-native locking (Terraform >= 1.10) -- no DynamoDB table
    encrypt      = true
  }
}
EOF
fi
echo "done."

echo
echo "== terraform init -migrate-state =="
echo "This will prompt to confirm copying existing local state into the new backend --"
echo "review the output below before answering."
(cd "$INFRA_DIR" && terraform init -migrate-state)

echo
echo "Remote backend active. Local terraform.tfstate/.backup files are left on disk"
echo "(already gitignored) but are no longer authoritative -- the S3 bucket is now the"
echo "source of truth for this project's state."
