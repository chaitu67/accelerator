#!/usr/bin/env bash
# Idempotent scaffold of the Terraform resources that provision Unity Catalog
# catalogs backed by external S3 storage: a reusable modules/catalog module
# (dedicated S3 bucket + IAM role + storage credential + external location +
# catalog + schemas per instance) instantiated via for_each over a `catalogs` map
# variable. Never overwrites files that already exist -- this includes the
# catalogs map itself: a new catalog is added by editing the committed
# catalogs.auto.tfvars directly (see SKILL.md Phase 1), not by this script.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCELERATOR_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel)"
WORKSPACE_ROOT="$(dirname "$ACCELERATOR_ROOT")"
INFRA_DIR="$WORKSPACE_ROOT/databricks/infrastructure"
MODULE_DIR="$INFRA_DIR/modules/catalog"

if [ ! -d "$INFRA_DIR" ]; then
  echo "Error: infrastructure/ not found at $INFRA_DIR" >&2
  echo "Run the 3.1-scaffold-infrastructure skill first." >&2
  exit 1
fi
if [ ! -f "$INFRA_DIR/account.auto.tfvars" ]; then
  echo "Error: account.auto.tfvars not found -> run 5.1-create-workspace's Phase 1 first" >&2
  echo "(databricks_account_id is shared with, and reused from, that file)." >&2
  exit 1
fi

WROTE_ANY=0

if [ -d "$MODULE_DIR" ] && [ -f "$MODULE_DIR/main.tf" ]; then
  echo "modules/catalog/ already exists -- reusing it as-is, not overwritten."
else
  mkdir -p "$MODULE_DIR"

  cat > "$MODULE_DIR/versions.tf" <<'EOF'
terraform {
  required_providers {
    # No configuration_aliases needed here, unlike modules/workspace -- catalogs,
    # schemas, storage credentials, and external locations are workspace-scoped
    # (Unity Catalog REST API on the workspace itself), not account-scoped, so this
    # module only uses the plain default `databricks`/`aws` providers, inherited
    # automatically from the root module.
    databricks = {
      source = "databricks/databricks"
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
  description = "Databricks account ID -- reused as the storage credential IAM role's external_id, same idiom as modules/workspace's cross-account role."
  type        = string
}

variable "name" {
  description = "Unity Catalog catalog name."
  type        = string
}

variable "comment" {
  description = "Optional comment/description for the catalog."
  type        = string
  default     = null
}

variable "bucket_name" {
  description = "Name of the S3 bucket backing this catalog's external storage location. Must be globally unique across ALL of S3, not just this AWS account."
  type        = string
}

variable "bucket_force_destroy" {
  description = "Allow `terraform destroy` to delete this bucket even if it still has objects in it. Defaults to false (AWS's own safe default); set true only for a disposable/test catalog where losing the data on teardown is fine."
  type        = bool
  default     = false
}

variable "storage_credential_role_name" {
  description = "Name of the IAM role Databricks assumes to access this catalog's S3 bucket via Unity Catalog."
  type        = string
}

variable "schemas" {
  description = "Schema names to create inside this catalog."
  type        = list(string)
  default     = []
}
EOF

  cat > "$MODULE_DIR/main.tf" <<'EOF'
# Provisions one Unity Catalog catalog backed by external S3 storage (a dedicated
# bucket + IAM role + storage credential + external location per catalog), plus its
# schemas. Does NOT create or assign a metastore -- most accounts already have one
# auto-provisioned and auto-assigned to every workspace (Databricks manages this by
# default for newer accounts); every UC resource below defaults to the workspace's
# current metastore assignment when metastore_id is left unset. If this account
# doesn't have one yet, create/assign it first -- this module doesn't do that.
#
# Uses the databricks provider's own `databricks_aws_unity_catalog_*` data sources
# to generate the IAM trust/permissions policies (the Unity-Catalog-specific
# analogues of modules/workspace's `databricks_aws_*` data sources for the
# cross-account role), rather than hand-maintained policy JSON.

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "catalog_storage" {
  bucket        = var.bucket_name
  force_destroy = var.bucket_force_destroy
}

resource "aws_s3_bucket_public_access_block" "catalog_storage" {
  bucket                  = aws_s3_bucket.catalog_storage.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "databricks_aws_unity_catalog_assume_role_policy" "this" {
  aws_account_id = data.aws_caller_identity.current.account_id
  role_name      = var.storage_credential_role_name
  external_id    = var.databricks_account_id
}

resource "aws_iam_role" "unity_catalog" {
  name               = var.storage_credential_role_name
  assume_role_policy = data.databricks_aws_unity_catalog_assume_role_policy.this.json
  tags               = { Name = var.storage_credential_role_name }
}

data "databricks_aws_unity_catalog_policy" "this" {
  aws_account_id = data.aws_caller_identity.current.account_id
  bucket_name    = var.bucket_name
  role_name      = var.storage_credential_role_name
}

resource "aws_iam_role_policy" "unity_catalog" {
  name   = "${var.storage_credential_role_name}-policy"
  role   = aws_iam_role.unity_catalog.id
  policy = data.databricks_aws_unity_catalog_policy.this.json
}

# Same IAM-eventual-consistency rationale as modules/workspace's iam_propagation:
# Databricks validates the role by actually assuming it when the storage credential
# is created, which can fail for a few seconds right after the policy is attached.
resource "time_sleep" "iam_propagation" {
  depends_on      = [aws_iam_role_policy.unity_catalog]
  create_duration = "30s"
}

resource "databricks_storage_credential" "this" {
  name = var.storage_credential_role_name
  aws_iam_role {
    role_arn    = aws_iam_role.unity_catalog.arn
    external_id = var.databricks_account_id
  }
  depends_on = [time_sleep.iam_propagation]
}

resource "databricks_external_location" "this" {
  name            = "${var.name}-external-location"
  url             = "s3://${aws_s3_bucket.catalog_storage.bucket}/${var.name}"
  credential_name = databricks_storage_credential.this.name
}

resource "databricks_catalog" "this" {
  name         = var.name
  comment      = var.comment
  storage_root = databricks_external_location.this.url
}

resource "databricks_schema" "this" {
  for_each     = toset(var.schemas)
  catalog_name = databricks_catalog.this.name
  name         = each.value
}
EOF

  cat > "$MODULE_DIR/outputs.tf" <<'EOF'
output "catalog_name" {
  value = databricks_catalog.this.name
}

output "external_location_url" {
  value = databricks_external_location.this.url
}

output "schema_full_names" {
  value = [for s in databricks_schema.this : "${var.name}.${s.name}"]
}
EOF

  echo "Created $MODULE_DIR/{versions,variables,main,outputs}.tf"
  WROTE_ANY=1
fi

if [ -f "$INFRA_DIR/catalogs.tf" ]; then
  echo "catalogs.tf already exists -- reusing it as-is, not overwritten."
else
  cat > "$INFRA_DIR/catalogs.tf" <<'EOF'
# One Unity Catalog catalog (external S3-backed storage) per entry in var.catalogs
# (see variables.tf) -- add a new catalog by adding an entry to the committed
# catalogs.auto.tfvars, never by editing this file or any CI workflow. Unlike
# workspaces.tf, no `providers = {}` block is needed: this module only uses the
# plain default databricks/aws providers (catalogs are workspace-scoped, not
# account-scoped).
module "catalog" {
  source   = "./modules/catalog"
  for_each = var.catalogs

  databricks_account_id        = var.databricks_account_id
  name                          = each.key
  comment                       = each.value.comment
  bucket_name                   = each.value.bucket_name
  bucket_force_destroy          = each.value.bucket_force_destroy
  storage_credential_role_name  = coalesce(each.value.storage_credential_role_name, "databricks-uc-${each.key}-storage")
  schemas                       = each.value.schemas
}
EOF
  echo "Created $INFRA_DIR/catalogs.tf"
  WROTE_ANY=1
fi

if grep -q '^variable "catalogs"' "$INFRA_DIR/variables.tf" 2>/dev/null; then
  echo "variables.tf already declares the catalogs map -- not touched."
else
  cat >> "$INFRA_DIR/variables.tf" <<'EOF'

variable "catalogs" {
  description = "Map of Unity Catalog catalogs to create, keyed by a short slug (the catalog name and the module instance key). Values come from the committed catalogs.auto.tfvars -- add an entry there to provision a new catalog; no CI/workflow changes needed. Each catalog gets its own dedicated S3 bucket + IAM role + storage credential + external location."
  type = map(object({
    comment                      = optional(string)
    bucket_name                  = string
    bucket_force_destroy         = optional(bool, false)
    storage_credential_role_name = optional(string)
    schemas                      = optional(list(string), [])
  }))
  default = {}
}
EOF
  echo "Appended the catalogs variable to $INFRA_DIR/variables.tf"
  WROTE_ANY=1
fi

if grep -q '^output "catalog_names"' "$INFRA_DIR/outputs.tf" 2>/dev/null; then
  echo "outputs.tf already has the aggregated catalog outputs -- not touched."
else
  cat >> "$INFRA_DIR/outputs.tf" <<'EOF'

output "catalog_names" {
  description = "Map of catalog slug -> catalog name, for every entry in var.catalogs."
  value       = { for k, m in module.catalog : k => m.catalog_name }
}

output "catalog_external_location_urls" {
  description = "Map of catalog slug -> external location S3 URL, for every entry in var.catalogs."
  value       = { for k, m in module.catalog : k => m.external_location_url }
}

output "catalog_schema_full_names" {
  description = "Map of catalog slug -> list of catalog.schema full names, for every entry in var.catalogs."
  value       = { for k, m in module.catalog : k => m.schema_full_names }
}
EOF
  echo "Appended aggregated catalog outputs to $INFRA_DIR/outputs.tf"
  WROTE_ANY=1
fi

echo
if [ "$WROTE_ANY" -eq 1 ]; then
  echo "Catalog module scaffolded. Next: add a real entry to the committed"
  echo "catalogs.auto.tfvars per SKILL.md Phase 1, then run deploy.sh."
else
  echo "Nothing to do -- module and catalogs.tf already scaffolded. To add a catalog,"
  echo "edit catalogs.auto.tfvars directly (Phase 1) -- this script has nothing left to do."
fi
