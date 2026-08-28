#!/usr/bin/env bash
# AWS authentication helper. Only runs steps that don't need interactive
# keyboard input (identity check, SSO browser login for an already-configured
# profile). Anything that needs a human typing a secret or picking an SSO
# account/role is printed as a command for the user to run in their own
# terminal -- never attempted here.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCELERATOR_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel)"
WORKSPACE_ROOT="$(dirname "$ACCELERATOR_ROOT")"
TFVARS="$WORKSPACE_ROOT/databricks/infrastructure/terraform.tfvars"

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI not installed -> run the 02-setup-local-env skill first." >&2
  exit 1
fi

PROFILE="${AWS_PROFILE:-}"
if [ -z "$PROFILE" ] && [ -f "$TFVARS" ]; then
  PROFILE="$(grep -E '^aws_profile' "$TFVARS" 2>/dev/null | sed -E 's/^aws_profile[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/')"
fi
[ -z "$PROFILE" ] && PROFILE="default"

# Deliberately not using a bash array for --profile: macOS ships bash 3.2 by
# default, where `"${arr[@]}"` on an empty array throws "unbound variable"
# under `set -u`. A plain function sidesteps that pitfall entirely.
aws_id() {
  if [ "$PROFILE" = "default" ]; then
    aws sts get-caller-identity --output json "$@"
  else
    aws sts get-caller-identity --profile "$PROFILE" --output json "$@"
  fi
}

echo "== Checking AWS identity (profile: $PROFILE) =="
IDENTITY_TMP="$(mktemp)"
trap 'rm -f "$IDENTITY_TMP"' EXIT

if aws_id >"$IDENTITY_TMP" 2>/dev/null; then
  ARN="$(grep -oE '"Arn": *"[^"]+"' "$IDENTITY_TMP" | cut -d'"' -f4)"
  echo "Already authenticated as $ARN"
  exit 0
fi

echo "Not authenticated for profile '$PROFILE'."
echo

if aws configure list-profiles 2>/dev/null | grep -qx "$PROFILE" \
   && grep -A5 "^\[profile $PROFILE\]" "$HOME/.aws/config" 2>/dev/null | grep -q "sso_"; then
  echo "Profile '$PROFILE' is SSO-configured. Opening browser for 'aws sso login'..."
  if aws sso login --profile "$PROFILE"; then
    aws_id | grep -oE '"Arn": *"[^"]+"'
    echo "Authenticated."
    exit 0
  fi
  echo "aws sso login failed or was cancelled." >&2
  exit 1
fi

cat <<EOF
No usable credentials found for profile '$PROFILE', and no SSO config exists for it yet.
Setting this up needs interactive input (browser account/role choice, or a secret access
key) this script can't supply. Which path applies depends on your AWS setup -- pick one:

--------------------------------------------------------------------------------
1) SSO (IAM Identity Center) -- only if this AWS account is part of an AWS
   Organization with Identity Center already enabled, and you've already been
   granted access to an account/permission set there (an AWS admin sets this up;
   it isn't something a single standalone account has by default). You'll need
   your org's SSO start URL (e.g. https://your-org.awsapps.com/start) and its
   region from whoever administers it.

   In your own terminal:
     aws configure sso --profile $PROFILE

--------------------------------------------------------------------------------
2) Static IAM access keys -- the standard path for a standalone AWS account
   (no Organizations). Pre-setup, one-time, in the AWS Console
   (https://console.aws.amazon.com/):
     a. IAM > Users > Create user (programmatic/CLI use -- no console access needed)
     b. Attach a permissions policy (AdministratorAccess is simplest to start with
        for a workshop/test account; scope it down later once you know exactly
        what the Terraform modules need)
     c. Open the new user > Security credentials tab > Create access key >
        use case "Command Line Interface (CLI)" > copy the Access Key ID and
        Secret Access Key (the secret is shown only once -- save it somewhere
        safe, never commit it to a repo)

   Then in your own terminal:
     aws configure --profile $PROFILE
   It prompts for the Access Key ID, Secret Access Key, a default region (e.g.
   us-east-1, matching the aws_region default in variables.tf), and output
   format (json).
--------------------------------------------------------------------------------

Then re-run this skill (or 3.2-check-prerequisites) to verify.
EOF
exit 1
