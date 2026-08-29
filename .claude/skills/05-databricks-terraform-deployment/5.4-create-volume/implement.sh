#!/usr/bin/env bash
# Idempotent scaffold of the Terraform resources that provision Unity Catalog
# volumes inside an existing catalog/schema: a reusable modules/volume module
# (one databricks_volume resource per instance) instantiated via for_each over
# a `volumes` map variable. Never overwrites files that already exist -- this
# includes the volumes map itself: a new volume is added by editing the
# committed volumes.auto.tfvars directly (see SKILL.md Phase 1), not by this
# script.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCELERATOR_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel)"
WORKSPACE_ROOT="$(dirname "$ACCELERATOR_ROOT")"
INFRA_DIR="$WORKSPACE_ROOT/databricks/infrastructure"
MODULE_DIR="$INFRA_DIR/modules/volume"

if [ ! -d "$INFRA_DIR" ]; then
  echo "Error: infrastructure/ not found at $INFRA_DIR" >&2
  echo "Run the 3.1-scaffold-infrastructure skill first." >&2
  exit 1
fi
if [ ! -f "$INFRA_DIR/modules/catalog/main.tf" ]; then
  echo "Error: modules/catalog/main.tf not found -> run 5.2-create-unity-catalog first" >&2
  echo "(volumes.tf references module.catalog[...] outputs directly)." >&2
  exit 1
fi

WROTE_ANY=0

if [ -d "$MODULE_DIR" ] && [ -f "$MODULE_DIR/main.tf" ]; then
  echo "modules/volume/ already exists -- reusing it as-is, not overwritten."
else
  mkdir -p "$MODULE_DIR"

  cat > "$MODULE_DIR/versions.tf" <<'EOF'
terraform {
  required_providers {
    # No configuration_aliases needed here, same reasoning as modules/catalog --
    # volumes are workspace-scoped (Unity Catalog REST API on the workspace
    # itself), not account-scoped, so this module only uses the plain default
    # `databricks` provider, inherited automatically from the root module.
    databricks = {
      source = "databricks/databricks"
    }
  }
}
EOF

  cat > "$MODULE_DIR/variables.tf" <<'EOF'
variable "catalog_name" {
  description = "Name of the Unity Catalog catalog this volume belongs to. Must already exist (created via 5.2-create-unity-catalog)."
  type        = string
}

variable "schema_name" {
  description = "Name of the schema within catalog_name this volume belongs to. Must already exist in that catalog's schemas list (also from 5.2-create-unity-catalog)."
  type        = string
}

variable "name" {
  description = "Volume name -- unique within catalog_name.schema_name, not globally."
  type        = string
}

variable "volume_type" {
  description = "\"MANAGED\" (default -- Databricks stores the volume's files under the owning schema's managed storage location automatically, no separate bucket/credential needed) or \"EXTERNAL\" (storage_location must already be covered by a registered external location's storage credential)."
  type        = string
  default     = "MANAGED"

  validation {
    condition     = contains(["MANAGED", "EXTERNAL"], var.volume_type)
    error_message = "volume_type must be \"MANAGED\" or \"EXTERNAL\"."
  }
}

variable "storage_location" {
  description = "S3 URL for this volume's storage. Required (and only used) when volume_type = \"EXTERNAL\" -- must be a path already covered by an existing external location's credential. Ignored for MANAGED volumes."
  type        = string
  default     = null
}

variable "comment" {
  description = "Optional comment/description for the volume."
  type        = string
  default     = null
}
EOF

  cat > "$MODULE_DIR/main.tf" <<'EOF'
# Provisions one Unity Catalog volume inside an existing catalog/schema
# (5.2-create-unity-catalog creates those). MANAGED volumes need nothing else --
# Databricks stores their files under the owning schema's managed storage
# location automatically. EXTERNAL volumes need storage_location to already be
# covered by a registered external location's storage credential; this module
# does NOT create a new bucket/IAM role/external location per volume the way
# modules/catalog does per catalog -- the root volumes.tf derives
# storage_location from the owning catalog's own external location by default
# (see its comment), so no new AWS/Databricks credential resources are needed
# for the common case of "external volume in the same bucket as its catalog."

resource "databricks_volume" "this" {
  name             = var.name
  catalog_name     = var.catalog_name
  schema_name      = var.schema_name
  volume_type      = var.volume_type
  storage_location = var.volume_type == "EXTERNAL" ? var.storage_location : null
  comment          = var.comment
}
EOF

  cat > "$MODULE_DIR/outputs.tf" <<'EOF'
output "volume_full_name" {
  value = "${var.catalog_name}.${var.schema_name}.${var.name}"
}

output "storage_location" {
  value = databricks_volume.this.storage_location
}
EOF

  echo "Created $MODULE_DIR/{versions,variables,main,outputs}.tf"
  WROTE_ANY=1
fi

if [ -f "$INFRA_DIR/volumes.tf" ]; then
  echo "volumes.tf already exists -- reusing it as-is, not overwritten."
else
  cat > "$INFRA_DIR/volumes.tf" <<'EOF'
# One Unity Catalog volume per entry in var.volumes (see variables.tf) -- add a
# new volume by adding an entry to the committed volumes.auto.tfvars, never by
# editing this file or any CI workflow. Workspace-scoped (plain default
# databricks provider), same as modules/catalog -- see 5.2-create-unity-catalog's
# SKILL.md "Key difference" for the gotcha this implies about which workspace
# these land in.
#
# EXTERNAL volumes default their storage_location to a subpath under the owning
# catalog's own external location (module.catalog[...].external_location_url)
# when not explicitly set -- avoids provisioning a new bucket/IAM
# role/external location per volume for the common case. An explicit
# storage_location is only needed to point a volume at a genuinely different,
# already-registered external location.
module "volume" {
  source   = "./modules/volume"
  for_each = var.volumes

  catalog_name = module.catalog[each.value.catalog].catalog_name
  schema_name  = each.value.schema
  name         = coalesce(each.value.name, each.key)
  volume_type  = each.value.volume_type
  comment      = each.value.comment
  storage_location = each.value.volume_type != "EXTERNAL" ? null : coalesce(
    each.value.storage_location,
    "${module.catalog[each.value.catalog].external_location_url}/${each.value.schema}/${coalesce(each.value.name, each.key)}"
  )
}
EOF
  echo "Created $INFRA_DIR/volumes.tf"
  WROTE_ANY=1
fi

if grep -q '^variable "volumes"' "$INFRA_DIR/variables.tf" 2>/dev/null; then
  echo "variables.tf already declares the volumes map -- not touched."
else
  cat >> "$INFRA_DIR/variables.tf" <<'EOF'

variable "volumes" {
  description = "Map of Unity Catalog volumes to create, keyed by an arbitrary slug. Values come from the committed volumes.auto.tfvars -- add an entry there to provision a new volume; no CI/workflow changes needed. `catalog` must reference an existing key in var.catalogs (5.2-create-unity-catalog); `schema` must already exist in that catalog's schemas list. `name` defaults to the map key when omitted -- set it explicitly only if the real Unity Catalog volume name should differ from the slug. `volume_type` is \"MANAGED\" (default -- no separate storage needed) or \"EXTERNAL\" (storage_location defaults to a subpath under the owning catalog's own external location when not set explicitly). See docs/naming-conventions.md: the effective name (`name`, or the map key when `name` is omitted) must match `<purpose>[_<subtype>]` -- lowercase, starting with a letter, underscore-separated -- enforced for every volume regardless of environment, since (unlike catalogs/groups) volumes have no separate environment field of their own; the owning catalog.schema already carries that context."
  type = map(object({
    catalog          = string
    schema           = string
    name             = optional(string)
    volume_type      = optional(string, "MANAGED")
    storage_location = optional(string)
    comment          = optional(string)
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, v in var.volumes : contains(["MANAGED", "EXTERNAL"], v.volume_type)
    ])
    error_message = "Each volume's volume_type must be \"MANAGED\" or \"EXTERNAL\"."
  }

  validation {
    # Unlike catalogs/groups, this is enforced unconditionally -- volumes have no environment
    # field of their own (the owning catalog.schema already carries env/domain context), so
    # there's no "dev is unrestricted" carve-out here. See docs/naming-conventions.md.
    condition = alltrue([
      for k, v in var.volumes : can(regex("^[a-z][a-z0-9]*(_[a-z][a-z0-9]*)*$", coalesce(v.name, k)))
    ])
    error_message = "Each volume's effective name (`name`, or the map key when `name` is omitted) must match <purpose>[_<subtype>] -- lowercase, starting with a letter, underscore-separated (e.g. raw_files, model_artifacts) -- see docs/naming-conventions.md."
  }
}
EOF
  echo "Appended the volumes variable to $INFRA_DIR/variables.tf"
  WROTE_ANY=1
fi

if grep -q '^output "volume_full_names"' "$INFRA_DIR/outputs.tf" 2>/dev/null; then
  echo "outputs.tf already has the aggregated volume outputs -- not touched."
else
  cat >> "$INFRA_DIR/outputs.tf" <<'EOF'

output "volume_full_names" {
  description = "Map of volume slug -> catalog.schema.volume full name, for every entry in var.volumes."
  value       = { for k, m in module.volume : k => m.volume_full_name }
}

output "volume_storage_locations" {
  description = "Map of volume slug -> resolved storage location (S3 URL for EXTERNAL, Databricks-managed path for MANAGED), for every entry in var.volumes."
  value       = { for k, m in module.volume : k => m.storage_location }
}
EOF
  echo "Appended aggregated volume outputs to $INFRA_DIR/outputs.tf"
  WROTE_ANY=1
fi

echo
if [ "$WROTE_ANY" -eq 1 ]; then
  echo "Volume module scaffolded. Next: add a real entry to the committed"
  echo "volumes.auto.tfvars per SKILL.md Phase 1, then run deploy.sh."
else
  echo "Nothing to do -- module and volumes.tf already scaffolded. To add a volume,"
  echo "edit volumes.auto.tfvars directly (Phase 1) -- this script has nothing left to do."
fi
