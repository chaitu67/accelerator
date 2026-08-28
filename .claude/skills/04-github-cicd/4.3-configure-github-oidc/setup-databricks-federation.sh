#!/usr/bin/env bash
# Idempotent setup of Databricks Workload Identity Federation for GitHub
# Actions: an account-level service principal, its workspace assignment, and
# two federation policies (one for pull_request-triggered plan runs, one for
# environment-gated apply runs). No Databricks secret is created or stored --
# GitHub's own OIDC token is exchanged for a Databricks token at run time.
#
# Requires account-level Databricks auth already set up (the ACCOUNT profile
# created by 05-databricks-terraform-deployment's deploy.sh / an account admin
# login) -- this is account-admin territory, same as workspace creation.
set -euo pipefail

REPO_SLUG="${1:-}"
DATABRICKS_HOST="${2:-}"
ENVIRONMENT_NAME="${3:-production}"
ACCOUNT_PROFILE="${4:-ACCOUNT}"

if [ -z "$REPO_SLUG" ] || [ -z "$DATABRICKS_HOST" ]; then
  echo "Usage: setup-databricks-federation.sh <owner/repo> <databricks-host> [environment-name] [account-profile]" >&2
  exit 1
fi

if ! command -v databricks >/dev/null 2>&1; then
  echo "databricks CLI not installed -> run the 02-setup-local-env skill first." >&2
  exit 1
fi

GH_ORG="${REPO_SLUG%%/*}"
REPO_NAME="${REPO_SLUG##*/}"
SP_DISPLAY_NAME="github-actions-${REPO_NAME}-terraform"
ISSUER="https://token.actions.githubusercontent.com"

# GitHub's actual `sub` claim embeds immutable owner/repo IDs by default --
# e.g. "repo:my-org@12345/my-repo@67890:pull_request", not the plain
# "repo:my-org/my-repo:pull_request" older docs/examples show (same issue
# setup-oidc.sh works around for AWS). Confirmed live: Databricks' own
# TOKEN_SUBJECT_INVALID error echoes back the exact subject/audience a
# passing policy needs -- that's the most reliable way to get this right,
# more so than any doc, since GitHub/Databricks can both change these details.
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  OWNER_ID="$(gh api "users/$GH_ORG" --jq .id 2>/dev/null || gh api "orgs/$GH_ORG" --jq .id 2>/dev/null || true)"
  REPO_ID="$(gh api "repos/$REPO_SLUG" --jq .id 2>/dev/null || true)"
fi

echo "== Checking account-level Databricks authentication (profile: $ACCOUNT_PROFILE) =="
# NOTE: `current-user me` is a workspace-scoped SCIM call and always fails against the
# accounts.cloud.databricks.com host this profile points at (no workspace context) -- checking
# the profile's own "valid" flag (same as 5.1-create-workspace's deploy.sh) is the correct check.
PROFILES_JSON="$(databricks auth profiles -o json 2>/dev/null || true)"

# The account-level (mws) provider requests an OIDC token audienced to the
# Databricks account ID itself, not a github.com/<org> URL -- confirmed live
# from a TOKEN_SUBJECT_INVALID error, which echoes back the exact
# subject/audience a passing policy needs. Trusting both audiences is
# defense in depth in case a plain (non-account-scoped) provider use ever
# requests the github.com/<org> form instead.
DATABRICKS_ACCOUNT_ID="$(echo "$PROFILES_JSON" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
for p in data.get('profiles', []):
    if p.get('name') == '$ACCOUNT_PROFILE':
        print(p.get('account_id', ''))
        break
" 2>/dev/null || true)"

AUDIENCES_JSON="[\"https://github.com/${GH_ORG}\"]"
if [ -n "${DATABRICKS_ACCOUNT_ID:-}" ]; then
  AUDIENCES_JSON="[\"https://github.com/${GH_ORG}\", \"${DATABRICKS_ACCOUNT_ID}\"]"
fi

ALREADY_VALID="$(echo "$PROFILES_JSON" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
for p in data.get('profiles', []):
    if p.get('name') == '$ACCOUNT_PROFILE' and p.get('valid'):
        print('yes')
        break
" 2>/dev/null || true)"

if [ "$ALREADY_VALID" != "yes" ]; then
  echo "Not authenticated for profile '$ACCOUNT_PROFILE'." >&2
  echo "Run: databricks auth login --host https://accounts.cloud.databricks.com --account-id <id> --profile $ACCOUNT_PROFILE" >&2
  echo "(This must be done by an ACCOUNT ADMIN, not just a workspace admin/user.)" >&2
  exit 1
fi
echo "Already authenticated."

echo
echo "== Service principal: $SP_DISPLAY_NAME =="
EXISTING_SP="$(databricks account service-principals list --profile "$ACCOUNT_PROFILE" -o json 2>/dev/null \
  | python3 -c "
import json, sys
sps = json.load(sys.stdin) or []
for sp in sps:
    if sp.get('displayName') == '$SP_DISPLAY_NAME':
        print(json.dumps(sp))
        break
")"

if [ -n "$EXISTING_SP" ]; then
  SP_ID="$(echo "$EXISTING_SP" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")"
  SP_APP_ID="$(echo "$EXISTING_SP" | python3 -c "import json,sys; print(json.load(sys.stdin)['applicationId'])")"
  echo "already exists -- reusing (id=$SP_ID, application_id=$SP_APP_ID)."
else
  CREATE_OUT="$(databricks account service-principals create --profile "$ACCOUNT_PROFILE" \
    --display-name "$SP_DISPLAY_NAME" -o json)"
  SP_ID="$(echo "$CREATE_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")"
  SP_APP_ID="$(echo "$CREATE_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['applicationId'])")"
  echo "created (id=$SP_ID, application_id=$SP_APP_ID)."
fi

echo
echo "== Workspace assignment =="
WORKSPACE_ID="$(grep -B5 "host *= *$DATABRICKS_HOST" "$HOME/.databrickscfg" 2>/dev/null \
  | grep -oE 'workspace_id *= *[0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
if [ -z "$WORKSPACE_ID" ]; then
  WORKSPACE_ID="$(grep -A5 '^\[DEFAULT\]' "$HOME/.databrickscfg" 2>/dev/null \
    | grep -oE 'workspace_id *= *[0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
fi
if [ -z "$WORKSPACE_ID" ]; then
  echo "Warning: could not resolve a numeric workspace_id for $DATABRICKS_HOST from ~/.databrickscfg." >&2
  echo "Skipping workspace assignment -- grant it manually: Account Console > Workspaces > "\
       "<workspace> > Permissions > add '$SP_DISPLAY_NAME'." >&2
else
  databricks account workspace-assignment update "$WORKSPACE_ID" "$SP_ID" \
    --profile "$ACCOUNT_PROFILE" --json '{"permissions": ["USER"]}' >/dev/null
  echo "assigned '$SP_DISPLAY_NAME' to workspace $WORKSPACE_ID with USER permission."
  echo "NOTE: USER is the minimal grant. If the Terraform-managed resources this pipeline will"
  echo "manage need more (e.g. catalog/cluster-policy/admin-level access), grant that manually in"
  echo "the workspace's admin console -- this script deliberately doesn't guess a broader scope."
fi

echo
echo "== Federation policies =="
existing_policy_subjects() {
  databricks account service-principal-federation-policy list "$SP_ID" --profile "$ACCOUNT_PROFILE" -o json 2>/dev/null \
    | python3 -c "
import json, sys
try:
    policies = json.load(sys.stdin) or []
except Exception:
    policies = []
for p in policies:
    oidc = p.get('oidcPolicy') or p.get('oidc_policy') or {}
    print(oidc.get('subject', ''))
"
}
CURRENT_SUBJECTS="$(existing_policy_subjects)"

create_policy() {
  local subject="$1" description="$2"
  if echo "$CURRENT_SUBJECTS" | grep -qxF "$subject"; then
    echo "policy for subject '$subject' already exists -- skipping."
    return
  fi
  databricks account service-principal-federation-policy create "$SP_ID" \
    --profile "$ACCOUNT_PROFILE" \
    --description "$description" \
    --json "{
      \"oidc_policy\": {
        \"issuer\": \"$ISSUER\",
        \"audiences\": $AUDIENCES_JSON,
        \"subject\": \"$subject\"
      }
    }" >/dev/null
  echo "created policy for subject '$subject'."
}

# Plain subject form (older docs/examples) -- kept for compatibility in case
# GitHub ever presents this form for some event type.
create_policy "repo:${REPO_SLUG}:pull_request" "GitHub Actions terraform-plan.yml (pull_request, plain subject)"
create_policy "repo:${REPO_SLUG}:environment:${ENVIRONMENT_NAME}" \
  "GitHub Actions terraform-apply.yml (environment: ${ENVIRONMENT_NAME}, plain subject)"

# Immutable-ID subject form -- what GitHub's tokens actually present today,
# confirmed live via Databricks' own TOKEN_SUBJECT_INVALID error message.
if [ -n "${OWNER_ID:-}" ] && [ -n "${REPO_ID:-}" ]; then
  SUB_PREFIX="repo:${GH_ORG}@${OWNER_ID}/${REPO_NAME}@${REPO_ID}"
  create_policy "${SUB_PREFIX}:pull_request" \
    "GitHub Actions terraform-plan.yml (pull_request, immutable-ID subject)"
  create_policy "${SUB_PREFIX}:environment:${ENVIRONMENT_NAME}" \
    "GitHub Actions terraform-apply.yml (environment: ${ENVIRONMENT_NAME}, immutable-ID subject)"
else
  echo "Warning: could not resolve owner/repo numeric IDs via gh -- only the plain subject form" >&2
  echo "was trusted. If GitHub presents immutable-ID subjects (the current default), auth will" >&2
  echo "fail with TOKEN_SUBJECT_INVALID; re-run this script once gh is authenticated." >&2
fi

echo
echo "== Repo variable: DATABRICKS_CLIENT_ID =="
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  gh variable set DATABRICKS_CLIENT_ID --repo "$REPO_SLUG" --body "$SP_APP_ID"
  echo "set DATABRICKS_CLIENT_ID = $SP_APP_ID (not a secret -- an application ID, safe as a"
  echo "plain repo variable; it grants no access without a matching federation policy)."
else
  echo "gh not authenticated -> set this yourself: gh variable set DATABRICKS_CLIENT_ID --repo $REPO_SLUG --body $SP_APP_ID" >&2
fi

echo
echo "Done. No Databricks secret was created or stored anywhere -- GitHub's own OIDC token is"
echo "exchanged for a Databricks token at each workflow run, scoped to exactly the pull_request /"
echo "environment:${ENVIRONMENT_NAME} subjects just configured."
