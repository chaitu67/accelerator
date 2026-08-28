#!/usr/bin/env bash
# Records the non-secret values GitHub Actions needs (AWS role ARN, region)
# as repo *variables*, and prints -- never runs or receives -- the exact
# `gh secret set` command for the one actual secret (Databricks CI
# credential). This script never sees, asks for, or transmits a secret value.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCELERATOR_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel)"
WORKSPACE_ROOT="$(dirname "$ACCELERATOR_ROOT")"
INFRA_DIR="$WORKSPACE_ROOT/databricks/infrastructure"

REPO_SLUG="${1:-}"
DATABRICKS_HOST="${2:-}"
CRED_TYPE="${3:-}" # "pat", "service-principal" (client secret), or "federated"; if omitted, prints all

if [ -z "$REPO_SLUG" ] || [ -z "$DATABRICKS_HOST" ]; then
  echo "Usage: setup-secrets.sh <owner/repo> <databricks-host> [pat|service-principal|federated]" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI not installed -> run the 02-setup-local-env skill first." >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "gh not authenticated -> run 'gh auth login' in your own terminal first." >&2
  exit 1
fi

ROLE_NAME="github-actions-$(basename "$REPO_SLUG")-terraform"
ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null || true)"
if [ -z "$ROLE_ARN" ]; then
  echo "Error: IAM role '$ROLE_NAME' not found -> run setup-oidc.sh first." >&2
  exit 1
fi

REGION=""
if [ -f "$INFRA_DIR/backend.tf" ]; then
  REGION="$(grep -oE 'region\s*=\s*"[^"]+"' "$INFRA_DIR/backend.tf" | head -1 | cut -d'"' -f2)"
fi
if [ -z "$REGION" ] && [ -f "$INFRA_DIR/terraform.tfvars" ]; then
  REGION="$(grep -E '^aws_region' "$INFRA_DIR/terraform.tfvars" | sed -E 's/^aws_region[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/')"
fi
[ -z "$REGION" ] && REGION="us-east-1"

echo "== Setting repo variables on $REPO_SLUG =="
gh variable set AWS_ROLE_TO_ASSUME --repo "$REPO_SLUG" --body "$ROLE_ARN"
echo "  AWS_ROLE_TO_ASSUME = $ROLE_ARN"
gh variable set AWS_REGION --repo "$REPO_SLUG" --body "$REGION"
echo "  AWS_REGION = $REGION"
gh variable set DATABRICKS_HOST --repo "$REPO_SLUG" --body "$DATABRICKS_HOST"
echo "  DATABRICKS_HOST = $DATABRICKS_HOST"

echo
echo "== Databricks CI credential (secret -- run this yourself, not via this script) =="
print_pat() {
  cat <<EOF
PAT path:
  gh secret set DATABRICKS_TOKEN --repo $REPO_SLUG
  (paste the token when prompted, or: echo "<token>" | gh secret set DATABRICKS_TOKEN --repo $REPO_SLUG)
  Generate the token first in the Databricks workspace: Settings > Developer > Access tokens.
EOF
}
print_sp() {
  cat <<EOF
Service principal + OAuth client secret (M2M) path:
  gh variable set DATABRICKS_CLIENT_ID --repo $REPO_SLUG --body <application-id>   (not a secret)
  gh secret set DATABRICKS_CLIENT_SECRET --repo $REPO_SLUG
  Create the service principal and its OAuth secret first in the Databricks Account Console:
  User management > Service principals > Add, then generate an OAuth secret for it, and grant
  it whatever workspace permissions the Terraform-managed resources need.
EOF
}
print_federated() {
  cat <<EOF
Federated (Workload Identity, no secret) path: already handled by
  setup-databricks-federation.sh $REPO_SLUG $DATABRICKS_HOST -- nothing more to run here.
  It creates the account-level service principal, its federation policies, and sets
  DATABRICKS_CLIENT_ID as a repo variable itself. No gh secret set needed for Databricks at all.
EOF
}

case "$CRED_TYPE" in
  pat) print_pat ;;
  service-principal) print_sp ;;
  federated) print_federated ;;
  *)
    echo "(no credential type given -- showing all three; pick the one matching Phase 1's answer)"
    echo
    print_pat
    echo
    print_sp
    echo
    print_federated
    ;;
esac

echo
echo "After running the gh secret set command(s) above yourself, re-run"
echo "4.1-check-cicd-prerequisites to confirm the secret is present (by name only)."
