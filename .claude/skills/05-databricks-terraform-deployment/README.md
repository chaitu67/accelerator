# 05-databricks-terraform-deployment skills

Skills numbered `5.x` in this group create **real, billed** Databricks/AWS infrastructure inside
the sibling `databricks` repo's `infrastructure/` Terraform project. This is the group that
actually runs `terraform apply` for the first time against real resources.

## Why this comes after 03 and 04, not right after 03

This group deliberately runs last in the setup sequence:

```
01-clone-sibling-repo          -> get the databricks repo
02-setup-local-env             -> local tooling (terraform, aws, databricks, gh)
03-terraform-setup             -> scaffold the Terraform project, confirm the environment
04-github-cicd                 -> remote S3 backend + GitHub Actions pipeline
05-databricks-terraform-deployment  -> THIS GROUP: the first real terraform apply
```

Earlier, `3.3-create-workspace` lived in the `03-terraform-setup` group and ran right after
scaffolding — meaning the very first `terraform apply` wrote to **local** state, and only later
(via `04-github-cicd`) would that state get migrated into S3. That's a real workspace/IAM/S3
footprint created under local state, then moved — extra risk and an extra step for no benefit.

Renumbering this as `05`, run *after* `04-github-cicd`, means:

- `backend.tf` already points at the S3 backend before this skill ever runs `terraform apply`.
- The AWS OIDC role `4.3-configure-github-oidc` created is already scoped and ready, so CI can
  manage this same infrastructure going forward without a separate credentials migration.
- State is clean, remote, and shared from the very first resource this project ever creates —
  nothing to migrate later.

## Skills in this group

- `5.1-create-workspace` — provisions Databricks-on-AWS workspaces (Databricks-managed VPC) via
  a shared `modules/workspace` Terraform module, instantiated per-workspace from a committed
  `workspaces.auto.tfvars` map: gather details, implement (scaffold the module — a no-op after
  the first workspace), deploy (plan → review → apply, either locally or through the
  `04-github-cicd` pipeline). Adding workspace #2+ is a single edit to that committed file —
  never a CI workflow or GitHub repo variable change.
- `5.2-create-unity-catalog` — creates Unity Catalog catalogs (with schemas) backed by external
  S3 storage, via a shared `modules/catalog` module instantiated per-catalog from a committed
  `catalogs.auto.tfvars` map — same standing pattern as `5.1`, but workspace-scoped (plain
  default `databricks` provider) rather than account-scoped, and assumes a metastore already
  exists/is assigned rather than creating one.
- `5.3-manage-catalog-access` — creates account-level Databricks groups (with members) via a
  shared `modules/group` module instantiated per-group from a committed `groups.auto.tfvars` map,
  and grants those groups privileges on catalogs/schemas (from `5.2`) via root-level
  `databricks_grants` resources instantiated per-grant from a committed
  `catalog_access.auto.tfvars` map. Mixes both provider scopes: groups are account-scoped (like
  `5.1`), grants are workspace-scoped (like `5.2`). Does not grant workspace login access itself
  — see its SKILL.md "Known gap."
- `5.4-create-volume` — creates Unity Catalog volumes (MANAGED or EXTERNAL) inside an existing
  catalog/schema (from `5.2`), via a shared `modules/volume` module instantiated per-volume from a
  committed `volumes.auto.tfvars` map. Workspace-scoped, same as `5.2`. EXTERNAL volumes default
  their storage location to a subpath under their own catalog's existing external location, rather
  than provisioning a new bucket/IAM role/external location per volume. Does not grant anyone
  read/write access to the volume itself — see its SKILL.md "Known gap."

## Naming conventions (catalogs and groups)

`5.2` and `5.3` both enforce an enterprise naming convention for `environment = "prod"`
catalogs/groups, via real Terraform `validation` blocks on `var.catalogs`/`var.groups` in
`databricks/infrastructure/variables.tf` (not just conversational discipline) — `dev`/`stg`
entries are never restricted. The canonical definition, including the group-type vocabulary
(`acl` implemented, `sp`/`abac` reserved for capabilities not yet built) lives in
`databricks/docs/naming-conventions.md` — read it before running `5.2`'s or `5.3`'s Phase 1 for
a `prod` entry.

## Before running anything in this group

Confirm `3.2-check-prerequisites` (base Terraform environment) **and**
`4.1-check-cicd-prerequisites` (remote backend, OIDC role, CI pipeline) both pass. `5.1` checks
this itself and tells you which to run if either is incomplete — don't skip straight here.

## Convention

- A new skill in this group gets the next `5.N` number and its own subdirectory:
  `05-databricks-terraform-deployment/5.N-<name>/`.
- If a `5.N` skill needs its own finer-grained steps, they nest one level deeper as
  `5.N.M-<name>/`, same rule as the `3.x`/`4.x` groups.
- Each still needs its own `SKILL.md` per the usual skill format — this README is an index for
  the group, not a skill itself.

## Constraints (apply to the whole group)

- Never runs before `04-github-cicd`'s prerequisites are confirmed — that ordering is the
  entire point of this group existing separately from `03-terraform-setup`.
- Never applies without a human-reviewed `plan` step first, whether that plan/apply happens
  locally or through the GitHub Actions pipeline.
- Never guesses account IDs, region, naming, or which AWS identity is active — always confirmed
  with the user first, since this group is where real, billed infrastructure actually gets
  created.
