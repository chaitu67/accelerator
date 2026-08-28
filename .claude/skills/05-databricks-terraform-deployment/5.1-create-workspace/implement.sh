#!/usr/bin/env bash
# Idempotent scaffold of the Terraform resources that provision Databricks-on-AWS
# workspaces (Databricks-managed VPC): account-level provider, plus a reusable
# modules/workspace module (cross-account IAM role, root S3 bucket, the
# databricks_mws_* resources) instantiated via for_each over a `workspaces` map
# variable. Never overwrites files that already exist -- this includes the
# workspaces map itself: a brand-new workspace is added by editing the committed
# workspaces.auto.tfvars directly (see SKILL.md Phase 1), not by this script,
# same way actual values never came from this script before modularization.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCELERATOR_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel)"
WORKSPACE_ROOT="$(dirname "$ACCELERATOR_ROOT")"
INFRA_DIR="$WORKSPACE_ROOT/databricks/infrastructure"
MODULE_DIR="$INFRA_DIR/modules/workspace"

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
  description = "Databricks account ID (Account Console > top right, or `cat ~/.databrickscfg` after any account-level login). Required to create a workspace. Value lives in the committed account.auto.tfvars -- not secret, and CI needs it too."
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

if [ -d "$MODULE_DIR" ] && [ -f "$MODULE_DIR/main.tf" ]; then
  echo "modules/workspace/ already exists -- reusing it as-is, not overwritten."
else
  mkdir -p "$MODULE_DIR"

  cat > "$MODULE_DIR/versions.tf" <<'EOF'
terraform {
  required_providers {
    # configuration_aliases is mandatory here: it's what lets the root module
    # pass its account-level `databricks.mws` provider instance into this
    # module's `databricks.mws` references below.
    databricks = {
      source                = "databricks/databricks"
      configuration_aliases = [databricks.mws]
    }
    aws = {
      source = "hashicorp/aws"
    }
    time = {
      source = "hashicorp/time"
    }
  }
}
EOF

  cat > "$MODULE_DIR/variables.tf" <<'EOF'
variable "databricks_account_id" {
  description = "Databricks account ID (shared across all workspace instances of this module)."
  type        = string
}

variable "display_name" {
  description = "Human-readable name for the workspace (shown in the Account Console)."
  type        = string
}

variable "deployment_name" {
  description = "Naming prefix for this workspace's Databricks account-level resources (credentials/storage config names) -- not the URL. The actual workspace URL is auto-assigned by Databricks (see the workspace_url output) unless this account has a deployment name prefix configured, which most don't."
  type        = string
}

variable "aws_region" {
  description = "AWS region to deploy this workspace into."
  type        = string
}

variable "root_bucket" {
  description = "Name of the S3 bucket used as this workspace's DBFS root. Must be globally unique across ALL of S3, not just this AWS account."
  type        = string
}

variable "root_bucket_force_destroy" {
  description = "Allow `terraform destroy` to delete this bucket even if it still has objects in it. Defaults to false (AWS's own safe default); set true only for a disposable workshop/test workspace where losing the data on teardown is fine."
  type        = bool
  default     = false
}

variable "cross_account_role_name" {
  description = "Name of the IAM role Databricks assumes to manage EC2/networking resources in this AWS account for this workspace."
  type        = string
}

variable "pricing_tier" {
  description = "Databricks pricing tier for this workspace: STANDARD, PREMIUM, or ENTERPRISE."
  type        = string
  default     = "PREMIUM"
}
EOF

  cat > "$MODULE_DIR/main.tf" <<'EOF'
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
  name               = var.cross_account_role_name
  assume_role_policy = data.databricks_aws_assume_role_policy.this.json
  tags               = { Name = var.cross_account_role_name }
}

data "databricks_aws_crossaccount_policy" "this" {
  provider = databricks.mws
}

resource "aws_iam_role_policy" "cross_account" {
  name   = "${var.cross_account_role_name}-policy"
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
  bucket        = var.root_bucket
  force_destroy = var.root_bucket_force_destroy
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
  credentials_name = "${var.deployment_name}-credentials"
  role_arn         = aws_iam_role.cross_account.arn
  depends_on       = [time_sleep.iam_propagation]
}

resource "databricks_mws_storage_configurations" "this" {
  provider                   = databricks.mws
  account_id                 = var.databricks_account_id
  storage_configuration_name = "${var.deployment_name}-storage"
  bucket_name                = aws_s3_bucket.root_storage.bucket
}

resource "databricks_mws_workspaces" "this" {
  provider       = databricks.mws
  account_id     = var.databricks_account_id
  workspace_name = var.display_name
  aws_region     = var.aws_region
  pricing_tier   = var.pricing_tier
  # deployment_name intentionally omitted: it errors with "Deployment name
  # cannot be used until a deployment name prefix is defined" on accounts
  # that don't have one configured (an account-level setting only Databricks
  # can set). Omitting it lets Databricks auto-assign the URL (the
  # dbc-<random>.cloud.databricks.com pattern) -- read it back from the
  # workspace_url output after apply.

  credentials_id           = databricks_mws_credentials.this.credentials_id
  storage_configuration_id = databricks_mws_storage_configurations.this.storage_configuration_id

  depends_on = [aws_s3_bucket_policy.root_storage, aws_iam_role_policy.cross_account]
}
EOF

  cat > "$MODULE_DIR/outputs.tf" <<'EOF'
output "workspace_url" {
  description = "URL of the workspace, once databricks_mws_workspaces reports RUNNING. Auto-assigned by Databricks (deployment_name is intentionally not set -- see main.tf)."
  value       = databricks_mws_workspaces.this.workspace_url
}

output "workspace_status" {
  value = databricks_mws_workspaces.this.workspace_status
}

output "workspace_id" {
  value = databricks_mws_workspaces.this.workspace_id
}
EOF

  echo "Created $MODULE_DIR/{versions,variables,main,outputs}.tf"
  WROTE_ANY=1
fi

if [ -f "$INFRA_DIR/workspaces.tf" ]; then
  echo "workspaces.tf already exists -- reusing it as-is, not overwritten."
else
  cat > "$INFRA_DIR/workspaces.tf" <<'EOF'
# One Databricks-on-AWS workspace per entry in var.workspaces (see variables.tf) --
# add a new workspace by adding an entry to the committed workspaces.auto.tfvars,
# never by editing this file or any CI workflow.
module "workspace" {
  source   = "./modules/workspace"
  for_each = var.workspaces

  providers = {
    databricks.mws = databricks.mws
  }

  databricks_account_id     = var.databricks_account_id
  display_name              = each.value.display_name
  deployment_name           = coalesce(each.value.deployment_name, each.key)
  aws_region                = coalesce(each.value.aws_region, var.aws_region)
  root_bucket               = each.value.root_bucket
  root_bucket_force_destroy = each.value.root_bucket_force_destroy
  cross_account_role_name   = coalesce(each.value.cross_account_role_name, "databricks-${each.key}-crossaccount")
  pricing_tier              = each.value.pricing_tier
}
EOF
  echo "Created $INFRA_DIR/workspaces.tf"
  WROTE_ANY=1
fi

if grep -q '^variable "workspaces"' "$INFRA_DIR/variables.tf" 2>/dev/null; then
  echo "variables.tf already declares the workspaces map -- not touched."
else
  cat >> "$INFRA_DIR/variables.tf" <<'EOF'

variable "workspaces" {
  description = "Map of Databricks workspaces to create, keyed by a short slug (used to default deployment_name/cross_account_role_name and as the module instance key). Values come from the committed workspaces.auto.tfvars -- add an entry there to provision a new workspace; no CI/workflow changes needed."
  type = map(object({
    display_name              = string
    deployment_name           = optional(string)
    aws_region                = optional(string)
    root_bucket               = string
    root_bucket_force_destroy = optional(bool, false)
    cross_account_role_name   = optional(string)
    pricing_tier              = optional(string, "PREMIUM")
  }))
  default = {}
}
EOF
  echo "Appended the workspaces variable to $INFRA_DIR/variables.tf"
  WROTE_ANY=1
fi

if grep -q '^output "workspace_urls"' "$INFRA_DIR/outputs.tf" 2>/dev/null; then
  echo "outputs.tf already has the aggregated workspace outputs -- not touched."
else
  cat >> "$INFRA_DIR/outputs.tf" <<'EOF'

output "workspace_urls" {
  description = "Map of workspace slug -> workspace URL, for every entry in var.workspaces."
  value       = { for k, m in module.workspace : k => m.workspace_url }
}

output "workspace_statuses" {
  description = "Map of workspace slug -> workspace_status, for every entry in var.workspaces."
  value       = { for k, m in module.workspace : k => m.workspace_status }
}
EOF
  echo "Appended aggregated workspace outputs to $INFRA_DIR/outputs.tf"
  WROTE_ANY=1
fi

echo
if [ "$WROTE_ANY" -eq 1 ]; then
  echo "Workspace module scaffolded. Next: add a real entry to the committed"
  echo "workspaces.auto.tfvars (and account.auto.tfvars, first time only) per SKILL.md"
  echo "Phase 1, then run deploy.sh."
else
  echo "Nothing to do -- module and workspaces.tf already scaffolded. To add a workspace,"
  echo "edit workspaces.auto.tfvars directly (Phase 1) -- this script has nothing left to do."
fi
