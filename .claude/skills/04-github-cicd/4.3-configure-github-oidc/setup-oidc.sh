#!/usr/bin/env bash
# Idempotent setup of AWS IAM OIDC federation for GitHub Actions: the
# token.actions.githubusercontent.com provider (shared across all repos in
# this AWS account that use GitHub OIDC) plus a role trusted only by the
# given repo. Never creates or handles a static AWS access key.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCELERATOR_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel)"
WORKSPACE_ROOT="$(dirname "$ACCELERATOR_ROOT")"
INFRA_DIR="$WORKSPACE_ROOT/databricks/infrastructure"

REPO_SLUG="${1:-}"
APPLY_BRANCH="${2:-main}"

if [ -z "$REPO_SLUG" ]; then
  echo "Usage: setup-oidc.sh <owner/repo> [allowed-apply-branch]" >&2
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI not installed -> run the 02-setup-local-env skill first." >&2
  exit 1
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ROLE_NAME="github-actions-$(basename "$REPO_SLUG")-terraform"
OIDC_HOST="token.actions.githubusercontent.com"
OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"

echo "== OIDC provider: $OIDC_HOST =="
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" >/dev/null 2>&1; then
  echo "already exists -- reusing it (shared across every repo using GitHub OIDC in this account)."
else
  # GitHub's OIDC token-signing certificate thumbprint. AWS no longer
  # actually validates this value against GitHub's cert for this specific
  # provider (it verifies the token signature directly), but the API still
  # requires a well-formed thumbprint list to create the provider.
  aws iam create-open-id-connect-provider \
    --url "https://${OIDC_HOST}" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1" >/dev/null
  echo "created: $OIDC_PROVIDER_ARN"
fi

echo
echo "== IAM role: $ROLE_NAME (trusts only repo:$REPO_SLUG) =="
# GitHub's actual `sub` claim now embeds immutable owner/repo IDs by default --
# e.g. "repo:my-org@12345/my-repo@67890:pull_request", not the plain
# "repo:my-org/my-repo:pull_request" older docs/examples show. Confirmed via
# CloudTrail on a real denied AssumeRoleWithWebIdentity call: matching only
# the plain form silently fails auth with "Not authorized to perform
# sts:AssumeRoleWithWebIdentity" and no further detail in the Actions log --
# CloudTrail's recorded `userIdentity.userName` is what actually reveals the
# real subject string. Trusting both forms is defense in depth in case a
# repo/org ever has immutable-ID subjects disabled.
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  OWNER_NAME="${REPO_SLUG%%/*}"
  REPO_NAME_ONLY="${REPO_SLUG##*/}"
  OWNER_ID="$(gh api "users/$OWNER_NAME" --jq .id 2>/dev/null || gh api "orgs/$OWNER_NAME" --jq .id 2>/dev/null || true)"
  REPO_ID="$(gh api "repos/$REPO_SLUG" --jq .id 2>/dev/null || true)"
fi

if [ -n "${OWNER_ID:-}" ] && [ -n "${REPO_ID:-}" ]; then
  SUB_IMMUTABLE="repo:${OWNER_NAME}@${OWNER_ID}/${REPO_NAME_ONLY}@${REPO_ID}:*"
  echo "resolved immutable IDs -- trusting subject '$SUB_IMMUTABLE' (and the plain form, as a fallback)."
  SUB_CONDITION="[\"repo:${REPO_SLUG}:*\", \"${SUB_IMMUTABLE}\"]"
else
  echo "Warning: could not resolve owner/repo numeric IDs via gh -- trusting only the plain" >&2
  echo "'repo:${REPO_SLUG}:*' subject form. If GitHub Actions runs default to immutable-ID" >&2
  echo "subjects for this repo, AssumeRoleWithWebIdentity will fail; re-run this script once" >&2
  echo "gh is authenticated to add the immutable-ID form too." >&2
  SUB_CONDITION="\"repo:${REPO_SLUG}:*\""
fi

TRUST_POLICY="$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "$OIDC_PROVIDER_ARN" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": { "${OIDC_HOST}:aud": "sts.amazonaws.com" },
        "StringLike": { "${OIDC_HOST}:sub": $SUB_CONDITION }
      }
    }
  ]
}
EOF
)"

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "already exists -- updating trust policy to current repo/OIDC provider values."
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$TRUST_POLICY"
else
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --description "GitHub Actions OIDC role for ${REPO_SLUG} (terraform plan/apply CI)" >/dev/null
  echo "created."
fi

ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)"

# Note: apply-vs-plan branch restriction (the $APPLY_BRANCH argument) is
# enforced in the workflow files (4.4-create-workflows), not the IAM trust
# policy -- the trust policy allows the whole repo (any branch/PR) to assume
# the role so plan can run on every PR; the apply workflow's own job-level
# `if: github.ref == 'refs/heads/$APPLY_BRANCH'` is what actually gates apply.
echo "(apply is restricted to the '$APPLY_BRANCH' branch at the workflow level, not IAM -- see 4.4-create-workflows)"

echo
echo "== Inline policy: terraform-backend-and-infra =="
# Scoped to what infrastructure/'s current resources need: the remote state
# backend (S3 + DynamoDB from 4.2-setup-remote-backend) and the AWS resource
# types workspace.tf manages (IAM role/policy, S3 bucket for DBFS root).
# Resource names for the *workspace's own* IAM role / S3 bucket aren't known
# ahead of time (they're user-chosen per deployment in terraform.tfvars), so
# those actions are scoped by service+action rather than a specific ARN --
# still far narrower than AdministratorAccess. Re-run this script after
# infrastructure/ grows new AWS resource types that need permissions not
# listed here.
STATE_BUCKET=""
STATE_TABLE=""
STATE_REGION=""
if [ -f "$INFRA_DIR/backend.tf" ]; then
  # `|| true` on each: grep exits non-zero when a pattern has no match (e.g. dynamodb_table is
  # legitimately absent under S3-native locking) -- without it, `pipefail` would abort the whole
  # script right here even though an empty result is an expected, valid case.
  STATE_BUCKET="$(grep -oE 'bucket\s*=\s*"[^"]+"' "$INFRA_DIR/backend.tf" | head -1 | cut -d'"' -f2 || true)"
  STATE_TABLE="$(grep -oE 'dynamodb_table\s*=\s*"[^"]+"' "$INFRA_DIR/backend.tf" | head -1 | cut -d'"' -f2 || true)"
  STATE_REGION="$(grep -oE 'region\s*=\s*"[^"]+"' "$INFRA_DIR/backend.tf" | head -1 | cut -d'"' -f2 || true)"
fi

if [ -z "$STATE_BUCKET" ]; then
  echo "Warning: backend.tf has no active S3 backend yet (run 4.2-setup-remote-backend first)." >&2
  echo "Attaching the policy without state-backend access for now -- re-run this script after 4.2." >&2
elif [ -z "$STATE_TABLE" ]; then
  echo "No dynamodb_table in backend.tf -- assuming S3-native locking (use_lockfile), no DynamoDB permissions needed."
fi

STATE_STATEMENTS="[]"
if [ -n "$STATE_BUCKET" ]; then
  STATE_STATEMENTS=$(cat <<EOF
[
  {
    "Sid": "TerraformStateBucket",
    "Effect": "Allow",
    "Action": ["s3:ListBucket"],
    "Resource": "arn:aws:s3:::${STATE_BUCKET}"
  },
  {
    "Sid": "TerraformStateObjects",
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
    "Resource": "arn:aws:s3:::${STATE_BUCKET}/*"
  }
]
EOF
  )
fi
if [ -n "$STATE_TABLE" ]; then
  STATE_STATEMENTS="$(echo "$STATE_STATEMENTS" | python3 -c "
import json,sys
stmts = json.load(sys.stdin)
stmts.append({
  'Sid': 'TerraformStateLock',
  'Effect': 'Allow',
  'Action': ['dynamodb:GetItem', 'dynamodb:PutItem', 'dynamodb:DeleteItem'],
  'Resource': 'arn:aws:dynamodb:${STATE_REGION}:${ACCOUNT_ID}:table/${STATE_TABLE}'
})
print(json.dumps(stmts))
")"
fi

INFRA_STATEMENTS='[
  {
    "Sid": "WorkspaceCrossAccountIamRole",
    "Effect": "Allow",
    "Action": [
      "iam:CreateRole", "iam:GetRole", "iam:DeleteRole", "iam:TagRole",
      "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy", "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies"
    ],
    "Resource": "arn:aws:iam::*:role/databricks-*"
  },
  {
    "Sid": "WorkspaceRootBucket",
    "Effect": "Allow",
    "Action": [
      "s3:CreateBucket", "s3:DeleteBucket", "s3:PutBucketPolicy",
      "s3:PutBucketPublicAccessBlock", "s3:PutBucketVersioning", "s3:PutEncryptionConfiguration"
    ],
    "Resource": "arn:aws:s3:::*dbfs-root*"
  },
  {
    "Sid": "WorkspaceRootBucketRead",
    "Effect": "Allow",
    "Action": ["s3:Get*", "s3:List*"],
    "Resource": ["arn:aws:s3:::*dbfs-root*", "arn:aws:s3:::*dbfs-root*/*"]
  }
]'

POLICY_DOCUMENT="$(python3 -c "
import json
state = json.loads('''$STATE_STATEMENTS''')
infra = json.loads('''$INFRA_STATEMENTS''')
print(json.dumps({'Version': '2012-10-17', 'Statement': state + infra}))
")"

aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "terraform-backend-and-infra" \
  --policy-document "$POLICY_DOCUMENT"
echo "attached/updated."

echo
echo "Role ARN: $ROLE_ARN"
echo "Next: run setup-secrets.sh $REPO_SLUG to record this ARN as a repo variable"
echo "and get the Databricks CI credential handoff command."
