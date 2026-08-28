#!/usr/bin/env bash
# Read-only audit of everything needed to run terraform init/plan/apply
# against the databricks/infrastructure Terraform project. Never installs,
# configures, or writes anything itself — only reports pass/fail and points
# at the skill/command that fixes each gap.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCELERATOR_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel)"
WORKSPACE_ROOT="$(dirname "$ACCELERATOR_ROOT")"
DATABRICKS_REPO="$WORKSPACE_ROOT/databricks"
INFRA_DIR="$DATABRICKS_REPO/infrastructure"

FAIL=0
ok()   { echo "  [OK]   $1"; }
warn() { echo "  [WARN] $1"; }
bad()  { echo "  [MISSING] $1"; FAIL=1; }

echo "== 1. Sibling databricks repo =="
if [ -d "$DATABRICKS_REPO/.git" ]; then
  ok "found at $DATABRICKS_REPO"
else
  bad "not found at $DATABRICKS_REPO -> run the 01-clone-sibling-repo skill"
fi

echo
echo "== 2. infrastructure/ Terraform scaffold =="
if [ -d "$INFRA_DIR" ]; then
  ok "found at $INFRA_DIR"
else
  bad "not found -> run the 3.1-scaffold-infrastructure skill"
fi

echo
echo "== 3. CLI tools =="
for bin in terraform aws databricks; do
  if command -v "$bin" >/dev/null 2>&1; then
    ok "$bin: $(command -v "$bin")"
  else
    bad "$bin not on PATH -> run the 02-setup-local-env skill"
  fi
done

if command -v terraform >/dev/null 2>&1; then
  TF_VERSION="$(terraform version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"
  # Read the actual constraint from versions.tf rather than hardcoding it here
  # -- 4.2-setup-remote-backend bumps this (1.5.0 -> 1.10.0) when it switches
  # the backend to S3-native locking, and this check should track that.
  REQ_VERSION="$(grep -oE 'required_version[[:space:]]*=[[:space:]]*">=\s*[0-9]+\.[0-9]+' "$INFRA_DIR/versions.tf" 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+' || echo "1.5")"
  REQ_MAJOR="${REQ_VERSION%%.*}"
  REQ_MINOR="${REQ_VERSION#*.}"
  if [ -n "$TF_VERSION" ]; then
    TF_MAJOR="${TF_VERSION%%.*}"
    TF_MINOR="$(echo "$TF_VERSION" | cut -d. -f2)"
    if [ "$TF_MAJOR" -gt "$REQ_MAJOR" ] || { [ "$TF_MAJOR" -eq "$REQ_MAJOR" ] && [ "$TF_MINOR" -ge "$REQ_MINOR" ]; }; then
      ok "terraform version $TF_VERSION satisfies >= $REQ_VERSION.0 (versions.tf constraint)"
    else
      bad "terraform version $TF_VERSION is older than the >= $REQ_VERSION.0 required in versions.tf -> upgrade via 'brew upgrade terraform'"
    fi
  fi
fi

echo
echo "== 4. AWS credentials =="
if command -v aws >/dev/null 2>&1; then
  if IDENTITY="$(aws sts get-caller-identity --output json 2>/dev/null)"; then
    ACCOUNT="$(echo "$IDENTITY" | grep -oE '"Account": *"[0-9]+"' | grep -oE '[0-9]+')"
    ARN="$(echo "$IDENTITY" | grep -oE '"Arn": *"[^"]+"' | cut -d'"' -f4)"
    ok "authenticated as $ARN (account $ACCOUNT)"
  else
    bad "'aws sts get-caller-identity' failed -> run the 3.2.1-authenticate-aws skill"
  fi
else
  warn "aws CLI not installed, skipping credential check (see CLI tools above)"
fi

echo
echo "== 5. Databricks credentials =="
if command -v databricks >/dev/null 2>&1; then
  if databricks current-user me >/dev/null 2>&1; then
    ok "authenticated ($(databricks current-user me 2>/dev/null | grep -oE '"userName": *"[^"]+"' | cut -d'"' -f4))"
  else
    bad "not authenticated ('databricks current-user me' failed) -> run the 3.2.2-authenticate-databricks skill"
  fi
else
  warn "databricks CLI not installed, skipping live auth check (see CLI tools above)"
  if [ -n "${DATABRICKS_HOST:-}" ] && [ -n "${DATABRICKS_TOKEN:-}" ]; then
    ok "DATABRICKS_HOST / DATABRICKS_TOKEN env vars set (host: $DATABRICKS_HOST)"
  elif [ -n "${TF_VAR_databricks_host:-}" ] && [ -n "${TF_VAR_databricks_token:-}" ]; then
    ok "TF_VAR_databricks_host / TF_VAR_databricks_token env vars set (host: $TF_VAR_databricks_host)"
  elif [ -f "$HOME/.databrickscfg" ]; then
    ok "found $HOME/.databrickscfg (from 'databricks configure') -- confirm it has the profile/token this deployment needs"
  elif [ -f "$INFRA_DIR/terraform.tfvars" ] && grep -q '^databricks_host' "$INFRA_DIR/terraform.tfvars" 2>/dev/null; then
    ok "databricks_host set in $INFRA_DIR/terraform.tfvars -- confirm databricks_token is supplied via TF_VAR_databricks_token, not committed to this file"
  else
    bad "no Databricks host/token found -> run the 3.2.2-authenticate-databricks skill"
  fi
fi

echo
echo "== 6. terraform.tfvars =="
if [ -f "$INFRA_DIR/terraform.tfvars" ]; then
  ok "found $INFRA_DIR/terraform.tfvars"
elif [ -d "$INFRA_DIR" ]; then
  warn "no terraform.tfvars yet -> copy $INFRA_DIR/terraform.tfvars.example to terraform.tfvars and fill in aws_region/aws_profile/databricks_host (it's gitignored)"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "All required prerequisites are in place."
else
  echo "One or more required prerequisites are missing (see [MISSING] above)."
fi
exit "$FAIL"
