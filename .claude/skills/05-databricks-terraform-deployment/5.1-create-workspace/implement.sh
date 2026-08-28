#!/usr/bin/env bash
# Idempotent scaffold of the Terraform resources that provision a NEW
# Databricks-on-AWS workspace (Databricks-managed VPC): account-level
# provider, cross-account IAM role, root S3 bucket, and the databricks_mws_*
# resources tying them together. Never overwrites files that already exist.
#
# This only writes generic, reusable resource/variable definitions -- it
# never writes actual values (workspace name, bucket name, account id) into
# terraform.tfvars. Those come from the conversational "gather details" step
# (see SKILL.md) and are filled in separately, since they're specific to one
# deployment and involve a globally-unique bucket name.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCELERATOR_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel)"
WORKSPACE_ROOT="$(dirname "$ACCELERATOR_ROOT")"
INFRA_DIR="$WORKSPACE_ROOT/databricks/infrastructure"

if [ ! -d "$INFRA_DIR" ]; then
  echo "Error: infrastructure/ not found at $INFRA_DIR" >&2
  echo "Run the 3.1-scaffold-infrastructure skill first." >&2
  exit 1
fi

WROTE_ANY=0

# Terraform allows only ONE required_providers block per module -- versions.tf
# (owned by 3.1-scaffold-infrastructure) already has one, so hashicorp/time
# (needed for the time_sleep.iam_propagation resource below) is inserted into
# it rather than declared in a second `terraform` block, which errors with
# "Duplicate required providers configuration". Coupled to the exact
# structure 3.1's init.sh writes -- fine, since these are sibling skills in
# the same group.
if [ -f "$INFRA_DIR/versions.tf" ] && ! grep -q 'hashicorp/time' "$INFRA_DIR/versions.tf" 2>/dev/null; then
  awk '
    /version[[:space:]]*=[[:space:]]*"~> 5\.0"/ {
      print
      getline
      print
      print "    time = {"
      print "      source  = \"hashicorp/time\""
      print "      version = \"~> 0.11\""
      print "    }"
      next
    }
    { print }
  ' "$INFRA_DIR/versions.tf" > "$INFRA_DIR/versions.tf.tmp" && mv "$INFRA_DIR/versions.tf.tmp" "$INFRA_DIR/versions.tf"
  echo "Added hashicorp/time to versions.tf's required_providers (needed for time_sleep.iam_propagation)."
  WROTE_ANY=1
fi

if [ -f "$INFRA_DIR/mws_provider.tf" ]; then
  echo "mws_provider.tf already exists -- reusing it as-is, not overwritten."
else
  cat > "$INFRA_DIR/mws_provider.tf" <<'EOF'
# Account-level Databricks provider, used only by resources that operate on
# the Databricks *account* (accounts.cloud.databricks.com) rather than a
# single workspace -- e.g. creating a new workspace itself. Distinct from
# the default `databricks` provider in providers.tf, which talks to one
# already-existing workspace.
#
# Local use: an ACCOUNT ADMIN runs, in their own terminal or via the
# 5.1-create-workspace skill's deploy.sh (which triggers this automatically):
#   databricks auth login --host https://accounts.cloud.databricks.com \
#     --account-id <databricks_account_id> --profile ACCOUNT
# This opens a browser for OAuth login and saves the result to the profile
# named by databricks_account_profile below.
#
# CI use (GitHub Actions, via 04-github-cicd/4.3-configure-github-oidc): same
# databricks_auth_type/databricks_client_id vars as the default provider in
# providers.tf -- profile is left null under github-oidc so it doesn't try to
# load a local ~/.databrickscfg profile that doesn't exist on a CI runner.
# The federation policy trusting this service principal must include a
# subject covering whatever triggers this (pull_request / environment:<name>)
# for account-level calls to succeed, same as workspace-level ones.
provider "databricks" {
  alias      = "mws"
  auth_type  = var.databricks_auth_type
  host       = "https://accounts.cloud.databricks.com"
  account_id = var.databricks_account_id
  client_id  = var.databricks_client_id
  profile    = var.databricks_auth_type == null ? var.databricks_account_profile : null
}

variable "databricks_account_id" {
  description = "Databricks account ID (Account Console > top right, or `cat ~/.databrickscfg` after any account-level login). Required to create a workspace."
  type        = string
}

variable "databricks_account_profile" {
  description = "~/.databrickscfg profile used for account-level auth. Created by `databricks auth login --host https://accounts.cloud.databricks.com --account-id <id> --profile <this>`."
  type        = string
  default     = "ACCOUNT"
}
EOF
  echo "Created $INFRA_DIR/mws_provider.tf"
  WROTE_ANY=1
fi

if [ -f "$INFRA_DIR/workspace.tf" ]; then
  echo "workspace.tf already exists -- reusing it as-is, not overwritten."
else
  cat > "$INFRA_DIR/workspace.tf" <<'EOF'
# Provisions one new Databricks-on-AWS workspace with a Databricks-managed
# VPC (Databricks creates and manages the VPC inside this AWS account --
# no pre-existing VPC/subnets required). Customer-managed VPC is not
# implemented here; see SKILL.md if that's needed instead.
#
# Uses the databricks provider's own `databricks_aws_*` data sources to
# generate the IAM trust policy, IAM permissions policy, and S3 bucket
# policy Databricks requires, rather than hand-maintained policy JSON --
# these stay correct as Databricks' requirements evolve.

data "databricks_aws_assume_role_policy" "this" {
  provider    = databricks.mws
  external_id = var.databricks_account_id
}

resource "aws_iam_role" "cross_account" {
  name               = var.new_workspace_cross_account_role_name
  assume_role_policy = data.databricks_aws_assume_role_policy.this.json
  tags               = { Name = var.new_workspace_cross_account_role_name }
}

data "databricks_aws_crossaccount_policy" "this" {
  provider = databricks.mws
}

resource "aws_iam_role_policy" "cross_account" {
  name   = "${var.new_workspace_cross_account_role_name}-policy"
  role   = aws_iam_role.cross_account.id
  policy = data.databricks_aws_crossaccount_policy.this.json
}

# IAM is eventually consistent -- Databricks validates the cross-account role by
# actually assuming it when databricks_mws_credentials is created, which can fail
# with "Failed credential validation checks" if that happens right after the role
# policy is attached. This wait absorbs that propagation delay.
resource "time_sleep" "iam_propagation" {
  depends_on      = [aws_iam_role_policy.cross_account]
  create_duration = "30s"
}

resource "aws_s3_bucket" "root_storage" {
  bucket        = var.new_workspace_root_bucket
  force_destroy = var.new_workspace_root_bucket_force_destroy
}

resource "aws_s3_bucket_public_access_block" "root_storage" {
  bucket                  = aws_s3_bucket.root_storage.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "databricks_aws_bucket_policy" "this" {
  provider = databricks.mws
  bucket   = aws_s3_bucket.root_storage.bucket
}

resource "aws_s3_bucket_policy" "root_storage" {
  bucket = aws_s3_bucket.root_storage.id
  policy = data.databricks_aws_bucket_policy.this.json
}

resource "databricks_mws_credentials" "this" {
  provider         = databricks.mws
  account_id       = var.databricks_account_id
  credentials_name = "${var.new_workspace_deployment_name}-credentials"
  role_arn         = aws_iam_role.cross_account.arn
  depends_on       = [time_sleep.iam_propagation]
}

resource "databricks_mws_storage_configurations" "this" {
  provider                   = databricks.mws
  account_id                 = var.databricks_account_id
  storage_configuration_name = "${var.new_workspace_deployment_name}-storage"
  bucket_name                = aws_s3_bucket.root_storage.bucket
}

resource "databricks_mws_workspaces" "this" {
  provider       = databricks.mws
  account_id     = var.databricks_account_id
  workspace_name = var.new_workspace_name
  aws_region     = var.new_workspace_aws_region
  pricing_tier   = var.new_workspace_pricing_tier
  # deployment_name intentionally omitted: it errors with "Deployment name
  # cannot be used until a deployment name prefix is defined" on accounts
  # that don't have one configured (an account-level setting only Databricks
  # can set). Omitting it lets Databricks auto-assign the URL (the
  # dbc-<random>.cloud.databricks.com pattern) -- read it back from the
  # new_workspace_url output after apply.

  credentials_id           = databricks_mws_credentials.this.credentials_id
  storage_configuration_id = databricks_mws_storage_configurations.this.storage_configuration_id

  depends_on = [aws_s3_bucket_policy.root_storage, aws_iam_role_policy.cross_account]
}

variable "new_workspace_name" {
  description = "Human-readable name for the new workspace (shown in the Account Console)."
  type        = string
}

variable "new_workspace_deployment_name" {
  description = "Naming prefix for this workspace's Databricks account-level resources (credentials/storage config names) -- not the URL. The actual workspace URL is auto-assigned by Databricks (see the new_workspace_url output) unless this account has a deployment name prefix configured, which most don't."
  type        = string
}

variable "new_workspace_aws_region" {
  description = "AWS region to deploy the new workspace into."
  type        = string
  default     = "us-east-1"
}

variable "new_workspace_root_bucket" {
  description = "Name of the new S3 bucket used as the workspace's DBFS root. Must be globally unique across ALL of S3, not just this AWS account."
  type        = string
}

variable "new_workspace_root_bucket_force_destroy" {
  description = "Allow `terraform destroy` to delete this bucket even if it still has objects in it. Defaults to false (AWS's own safe default); set true only for a disposable workshop/test workspace where losing the data on teardown is fine."
  type        = bool
  default     = false
}

variable "new_workspace_cross_account_role_name" {
  description = "Name of the IAM role Databricks assumes to manage EC2/networking resources in this AWS account for the new workspace."
  type        = string
  default     = "databricks-crossaccount-role"
}

variable "new_workspace_pricing_tier" {
  description = "Databricks pricing tier for the new workspace: STANDARD, PREMIUM, or ENTERPRISE."
  type        = string
  default     = "PREMIUM"
}

output "new_workspace_url" {
  description = "URL of the newly created workspace, once databricks_mws_workspaces reports RUNNING. Auto-assigned by Databricks (deployment_name is intentionally not set -- see workspace.tf)."
  value       = databricks_mws_workspaces.this.workspace_url
}

output "new_workspace_status" {
  value = databricks_mws_workspaces.this.workspace_status
}
EOF
  echo "Created $INFRA_DIR/workspace.tf"
  WROTE_ANY=1
fi

MARKER="# --- 5.1-create-workspace example values ---"
if grep -qF "$MARKER" "$INFRA_DIR/terraform.tfvars.example" 2>/dev/null; then
  echo "terraform.tfvars.example already has 5.1-create-workspace example values."
else
  cat >> "$INFRA_DIR/terraform.tfvars.example" <<EOF

$MARKER
databricks_account_id                   = "<databricks-account-id-from-account-console>"
databricks_account_profile              = "ACCOUNT"
new_workspace_name                      = "my-new-workspace"
new_workspace_deployment_name           = "my-new-workspace"
new_workspace_aws_region                = "us-east-1"
new_workspace_root_bucket               = "my-new-workspace-dbfs-root-<unique-suffix>"
new_workspace_root_bucket_force_destroy = false
new_workspace_cross_account_role_name   = "databricks-my-new-workspace-crossaccount"
new_workspace_pricing_tier              = "PREMIUM"
EOF
  echo "Appended example values to $INFRA_DIR/terraform.tfvars.example"
  WROTE_ANY=1
fi

echo
if [ "$WROTE_ANY" -eq 1 ]; then
  echo "Workspace-creation resources scaffolded. Next: fill real values into terraform.tfvars (not committed to git), then run deploy.sh."
else
  echo "Nothing to do -- all files already scaffolded."
fi
