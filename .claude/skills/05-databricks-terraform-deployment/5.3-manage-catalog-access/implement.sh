#!/usr/bin/env bash
# Idempotent scaffold of the Terraform resources that manage Unity Catalog access:
# a reusable modules/group module (account-level databricks_group + members,
# instantiated via for_each over a `groups` map variable) plus root-level
# databricks_grants resources (workspace-scoped, for_each over a `catalog_grants`
# map variable) that grant those groups privileges on catalogs/schemas from
# modules/catalog. Never overwrites files that already exist -- this includes the
# groups/catalog_grants maps themselves: a new group or grant is added by editing
# the committed groups.auto.tfvars / catalog_access.auto.tfvars directly (see
# SKILL.md Phase 1), not by this script.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCELERATOR_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel)"
WORKSPACE_ROOT="$(dirname "$ACCELERATOR_ROOT")"
INFRA_DIR="$WORKSPACE_ROOT/databricks/infrastructure"
MODULE_DIR="$INFRA_DIR/modules/group"

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
if [ ! -f "$INFRA_DIR/modules/catalog/main.tf" ]; then
  echo "Error: modules/catalog/main.tf not found -> run 5.2-create-unity-catalog first" >&2
  echo "(catalog_access.tf's grants reference module.catalog outputs directly)." >&2
  exit 1
fi

WROTE_ANY=0

if [ -d "$MODULE_DIR" ] && [ -f "$MODULE_DIR/main.tf" ]; then
  echo "modules/group/ already exists -- reusing it as-is, not overwritten."
else
  mkdir -p "$MODULE_DIR"

  cat > "$MODULE_DIR/versions.tf" <<'EOF'
terraform {
  required_providers {
    # configuration_aliases is mandatory here, same as modules/workspace: group
    # creation and membership are account-level operations (accounts.cloud.databricks.com),
    # not workspace-scoped, so this module needs the root module's databricks.mws
    # provider instance passed in explicitly.
    databricks = {
      source                = "databricks/databricks"
      configuration_aliases = [databricks.mws]
    }
  }
}
EOF

  cat > "$MODULE_DIR/variables.tf" <<'EOF'
variable "name" {
  description = "Account-level Databricks group display name."
  type        = string
}

variable "member_emails" {
  description = "Email addresses of existing Databricks account users to add as members of this group. Users must already exist in this Databricks account -- this module only looks them up (via the databricks_user data source), never provisions them."
  type        = list(string)
  default     = []
}
EOF

  cat > "$MODULE_DIR/main.tf" <<'EOF'
# Provisions one account-level Databricks group and its members. Account-level
# (not workspace-level) because Unity Catalog privilege grants (see the root
# catalog_access.tf, in 5.3-manage-catalog-access) operate on account/metastore-level
# principals -- the same reason modules/workspace looks up databricks_user by email
# for its admin_emails assignment, rather than anything workspace-scoped.

resource "databricks_group" "this" {
  provider     = databricks.mws
  display_name = var.name
}

data "databricks_user" "members" {
  for_each  = toset(var.member_emails)
  provider  = databricks.mws
  user_name = each.value
}

resource "databricks_group_member" "this" {
  for_each  = toset(var.member_emails)
  provider  = databricks.mws
  group_id  = databricks_group.this.id
  member_id = data.databricks_user.members[each.key].id
}
EOF

  cat > "$MODULE_DIR/outputs.tf" <<'EOF'
output "group_id" {
  value = databricks_group.this.id
}

output "group_name" {
  value = databricks_group.this.display_name
}
EOF

  echo "Created $MODULE_DIR/{versions,variables,main,outputs}.tf"
  WROTE_ANY=1
fi

if [ -f "$INFRA_DIR/groups.tf" ]; then
  echo "groups.tf already exists -- reusing it as-is, not overwritten."
else
  cat > "$INFRA_DIR/groups.tf" <<'EOF'
# One account-level Databricks group (with members) per entry in var.groups (see
# variables.tf) -- add a new group by adding an entry to the committed
# groups.auto.tfvars, never by editing this file or any CI workflow. Same
# providers = {} idiom as workspaces.tf: group creation/membership is
# account-scoped, not workspace-scoped.
module "group" {
  source   = "./modules/group"
  for_each = var.groups

  providers = {
    databricks.mws = databricks.mws
  }

  name          = each.key
  member_emails = each.value.member_emails
}
EOF
  echo "Created $INFRA_DIR/groups.tf"
  WROTE_ANY=1
fi

if [ -f "$INFRA_DIR/catalog_access.tf" ]; then
  echo "catalog_access.tf already exists -- reusing it as-is, not overwritten."
else
  cat > "$INFRA_DIR/catalog_access.tf" <<'EOF'
# Unity Catalog privilege grants, one databricks_grants resource per catalog-or-schema
# securable in var.catalog_grants (see variables.tf) -- add a new grant by adding an
# entry to the committed catalog_access.auto.tfvars, never by editing this file or any
# CI workflow. Split into two resources (catalog vs. schema) because databricks_grants
# takes exactly one securable argument -- an entry sets exactly one of them via
# `schema` being null or not. Workspace-scoped (plain default databricks provider),
# same as modules/catalog -- see 5.2-create-unity-catalog's SKILL.md "Key difference"
# for the gotcha this implies about which workspace these land in.
resource "databricks_grants" "catalog" {
  for_each = { for k, v in var.catalog_grants : k => v if v.schema == null }
  catalog  = module.catalog[each.value.catalog].catalog_name

  dynamic "grant" {
    for_each = each.value.grants
    content {
      principal  = module.group[grant.value.group].group_name
      privileges = grant.value.privileges
    }
  }
}

resource "databricks_grants" "schema" {
  for_each = { for k, v in var.catalog_grants : k => v if v.schema != null }
  schema   = "${module.catalog[each.value.catalog].catalog_name}.${each.value.schema}"

  dynamic "grant" {
    for_each = each.value.grants
    content {
      principal  = module.group[grant.value.group].group_name
      privileges = grant.value.privileges
    }
  }
}
EOF
  echo "Created $INFRA_DIR/catalog_access.tf"
  WROTE_ANY=1
fi

if grep -q '^variable "groups"' "$INFRA_DIR/variables.tf" 2>/dev/null; then
  echo "variables.tf already declares the groups map -- not touched."
else
  cat >> "$INFRA_DIR/variables.tf" <<'EOF'

variable "groups" {
  description = "Map of account-level Databricks groups to create, keyed by a short slug (used as the group's display name and module instance key). Values come from the committed groups.auto.tfvars -- add an entry there to provision a new group; no CI/workflow changes needed. Groups are account-level (shared across every workspace attached to this account), matching how Unity Catalog grants work."
  type = map(object({
    member_emails = optional(list(string), [])
  }))
  default = {}
}
EOF
  echo "Appended the groups variable to $INFRA_DIR/variables.tf"
  WROTE_ANY=1
fi

if grep -q '^variable "catalog_grants"' "$INFRA_DIR/variables.tf" 2>/dev/null; then
  echo "variables.tf already declares the catalog_grants map -- not touched."
else
  cat >> "$INFRA_DIR/variables.tf" <<'EOF'

variable "catalog_grants" {
  description = "Map of Unity Catalog privilege grants, keyed by an arbitrary slug. Each entry grants one or more groups' privileges on either a whole catalog (schema left null) or one schema within it (schema set). Values come from the committed catalog_access.auto.tfvars -- add an entry there to grant access; no CI/workflow changes needed. `catalog` must reference an existing key in var.catalogs (5.2-create-unity-catalog); `group` in each grants[] entry must reference an existing key in var.groups."
  type = map(object({
    catalog = string
    schema  = optional(string)
    grants = list(object({
      group      = string
      privileges = list(string)
    }))
  }))
  default = {}
}
EOF
  echo "Appended the catalog_grants variable to $INFRA_DIR/variables.tf"
  WROTE_ANY=1
fi

if grep -q '^output "group_names"' "$INFRA_DIR/outputs.tf" 2>/dev/null; then
  echo "outputs.tf already has the group_names output -- not touched."
else
  cat >> "$INFRA_DIR/outputs.tf" <<'EOF'

output "group_names" {
  description = "Map of group slug -> group display name, for every entry in var.groups."
  value       = { for k, m in module.group : k => m.group_name }
}
EOF
  echo "Appended the group_names output to $INFRA_DIR/outputs.tf"
  WROTE_ANY=1
fi

echo
if [ "$WROTE_ANY" -eq 1 ]; then
  echo "Group/access module scaffolded. Next: add real entries to the committed"
  echo "groups.auto.tfvars and/or catalog_access.auto.tfvars per SKILL.md Phase 1,"
  echo "then run deploy.sh."
else
  echo "Nothing to do -- module, groups.tf, and catalog_access.tf already scaffolded."
  echo "To add a group or grant, edit groups.auto.tfvars / catalog_access.auto.tfvars"
  echo "directly (Phase 1) -- this script has nothing left to do."
fi
