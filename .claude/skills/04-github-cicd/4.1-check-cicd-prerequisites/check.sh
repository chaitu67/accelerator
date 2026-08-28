#!/usr/bin/env bash
# Read-only audit of everything needed for GitHub Actions CI/CD to run
# terraform plan/apply against the databricks/infrastructure Terraform
# project. Never installs, configures, or writes anything — only reports
# pass/fail and points at the skill/command that fixes each gap.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCELERATOR_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel)"
WORKSPACE_ROOT="$(dirname "$ACCELERATOR_ROOT")"
DATABRICKS_REPO="$WORKSPACE_ROOT/databricks"
INFRA_DIR="$DATABRICKS_REPO/infrastructure"
WORKFLOWS_DIR="$DATABRICKS_REPO/.github/workflows"

FAIL=0
ok()   { echo "  [OK]   $1"; }
warn() { echo "  [WARN] $1"; }
bad()  { echo "  [MISSING] $1"; FAIL=1; }

echo "== 1. Base 03-terraform-setup prerequisites =="
BASE_CHECK="$ACCELERATOR_ROOT/.claude/skills/03-terraform-setup/3.2-check-prerequisites/check.sh"
if [ -x "$BASE_CHECK" ] || [ -f "$BASE_CHECK" ]; then
  if bash "$BASE_CHECK" >/tmp/04-cicd-base-check.$$ 2>&1; then
    ok "base Terraform prerequisites all pass (repo, scaffold, CLIs, AWS/Databricks auth)"
  else
    bad "base Terraform prerequisites incomplete -> run 3.2-check-prerequisites for details:"
    sed 's/^/           /' /tmp/04-cicd-base-check.$$
  fi
  rm -f /tmp/04-cicd-base-check.$$
else
  warn "3.2-check-prerequisites/check.sh not found -- skipping base check"
fi

echo
echo "== 2. GitHub remote =="
REPO_SLUG=""
if [ -d "$DATABRICKS_REPO/.git" ]; then
  REMOTE_URL="$(git -C "$DATABRICKS_REPO" remote get-url origin 2>/dev/null || true)"
  if [ -n "$REMOTE_URL" ]; then
    # Normalize both git@github.com:owner/repo.git and https://github.com/owner/repo.git
    REPO_SLUG="$(echo "$REMOTE_URL" | sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##')"
    if echo "$REMOTE_URL" | grep -q 'github.com'; then
      ok "origin is a GitHub repo: $REPO_SLUG"
    else
      bad "origin ($REMOTE_URL) is not a github.com URL -- this group only supports GitHub Actions"
    fi
  else
    bad "no 'origin' remote found on $DATABRICKS_REPO"
  fi
else
  bad "databricks repo not found at $DATABRICKS_REPO -> run the 01-clone-sibling-repo skill"
fi

echo
echo "== 3. GitHub CLI (gh) =="
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    ok "gh installed and authenticated ($(gh auth status 2>&1 | grep -oE 'account [^ ]+' | head -1))"
  else
    bad "gh installed but not authenticated -> run 'gh auth login' in your own terminal"
  fi
else
  bad "gh CLI not on PATH -> run the 02-setup-local-env skill"
fi

echo
echo "== 4. Remote Terraform backend =="
if [ -f "$INFRA_DIR/backend.tf" ]; then
  if grep -qE '^\s*backend\s+"s3"\s*\{' "$INFRA_DIR/backend.tf" 2>/dev/null; then
    ok "backend.tf has an active S3 backend block"
    # backend.tf declaring an S3 block isn't proof the migration actually ran -- `terraform
    # init -migrate-state` needs a human to confirm its prompt (4.2-setup-remote-backend never
    # auto-answers it), so this can be written but not yet acted on. Confirm state actually
    # landed in S3 before calling this OK.
    BUCKET="$(grep -oE 'bucket\s*=\s*"[^"]+"' "$INFRA_DIR/backend.tf" | head -1 | cut -d'"' -f2 || true)"
    KEY="$(grep -oE 'key\s*=\s*"[^"]+"' "$INFRA_DIR/backend.tf" | head -1 | cut -d'"' -f2 || true)"
    if command -v aws >/dev/null 2>&1 && [ -n "$BUCKET" ] && [ -n "$KEY" ]; then
      if aws s3api head-object --bucket "$BUCKET" --key "$KEY" >/dev/null 2>&1; then
        ok "state object confirmed in s3://$BUCKET/$KEY -- migration actually completed"
      else
        bad "backend.tf points at s3://$BUCKET/$KEY but no object exists there yet -> run 'terraform init -migrate-state' in infrastructure/ (interactive; confirm its prompt yourself)"
      fi
    else
      warn "aws CLI unavailable or bucket/key unparseable -- can't confirm the migration actually ran"
    fi
  else
    bad "backend.tf still has local state (S3 backend block is commented out) -> run 4.2-setup-remote-backend"
  fi
else
  bad "backend.tf not found -> run 3.1-scaffold-infrastructure first"
fi

echo
echo "== 5. AWS OIDC provider + role for GitHub Actions =="
if command -v aws >/dev/null 2>&1; then
  OIDC_ARN="$(aws iam list-open-id-connect-providers --output text 2>/dev/null \
    | grep -oE 'arn:aws:iam::[0-9]+:oidc-provider/token\.actions\.githubusercontent\.com' | head -1)"
  if [ -n "$OIDC_ARN" ]; then
    ok "OIDC provider exists: $OIDC_ARN"
  else
    bad "no token.actions.githubusercontent.com OIDC provider in this AWS account -> run 4.3-configure-github-oidc"
  fi

  if [ -n "$REPO_SLUG" ]; then
    ROLE_NAME="github-actions-$(basename "$REPO_SLUG")-terraform"
    if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
      ok "IAM role exists: $ROLE_NAME"
    else
      bad "IAM role '$ROLE_NAME' not found -> run 4.3-configure-github-oidc"
    fi
  else
    warn "can't check for the IAM role without a resolved repo slug (see section 2)"
  fi
else
  warn "aws CLI not installed, skipping OIDC/role check (see base check above)"
fi

echo
echo "== 6. GitHub repo variables/secrets =="
if command -v gh >/dev/null 2>&1 && [ -n "$REPO_SLUG" ] && gh auth status >/dev/null 2>&1; then
  VARS="$(gh variable list --repo "$REPO_SLUG" 2>/dev/null | awk '{print $1}')"
  for v in AWS_ROLE_TO_ASSUME AWS_REGION DATABRICKS_HOST; do
    if echo "$VARS" | grep -qx "$v"; then
      ok "repo variable set: $v"
    else
      bad "repo variable '$v' not set -> run 4.3-configure-github-oidc"
    fi
  done

  SECRETS="$(gh secret list --repo "$REPO_SLUG" 2>/dev/null | awk '{print $1}')"
  if echo "$VARS" | grep -qx "DATABRICKS_CLIENT_ID" && echo "$SECRETS" | grep -qx "DATABRICKS_CLIENT_SECRET"; then
    ok "repo credential set: DATABRICKS_CLIENT_ID (variable) + DATABRICKS_CLIENT_SECRET (secret) -- OAuth M2M"
  elif echo "$VARS" | grep -qx "DATABRICKS_CLIENT_ID"; then
    ok "repo variable set: DATABRICKS_CLIENT_ID -- federated (workload identity, no secret needed)"
  elif echo "$SECRETS" | grep -qx "DATABRICKS_TOKEN"; then
    ok "repo secret set: DATABRICKS_TOKEN (PAT)"
  else
    bad "no Databricks CI credential found (DATABRICKS_CLIENT_ID variable for the federated/M2M paths, or DATABRICKS_TOKEN secret for PAT) -> run 4.3-configure-github-oidc"
  fi
else
  warn "can't check repo variables/secrets without gh authenticated and a resolved repo slug"
fi

echo
echo "== 7. Workflow files =="
for f in terraform-plan.yml terraform-apply.yml; do
  if [ -f "$WORKFLOWS_DIR/$f" ]; then
    ok "found $f"
  else
    bad "$f not found -> run 4.4-create-workflows"
  fi
done

echo
if [ "$FAIL" -eq 0 ]; then
  echo "All CI/CD prerequisites are in place."
else
  echo "One or more CI/CD prerequisites are missing (see [MISSING] above)."
fi
exit "$FAIL"
