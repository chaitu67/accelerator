---
name: 5.2-create-unity-catalog
description: Create Unity Catalog catalogs (with schemas) backed by external S3 storage, via a shared modules/catalog Terraform module instantiated per-catalog from a committed catalogs.auto.tfvars map -- gathers details, scaffolds the module (once), then deploys (plan, review, apply). Adding a second (or Nth) catalog never requires touching CI workflow files or GitHub repo variables -- only this one committed tfvars file changes. Use when the user asks to create a Unity Catalog catalog, schema, or external storage location via Terraform.
---

# Create Unity Catalog (databricks repo)

Second skill in the `05-databricks-terraform-deployment` group, alongside
[5.1-create-workspace](../5.1-create-workspace/SKILL.md) — see [../README.md](../README.md).
Same standing pattern (reusable module + `for_each` + committed `*.auto.tfvars`, no CI edits per
instance), applied to Unity Catalog catalogs instead of workspaces.

**Scope**: creates catalogs (each with its own dedicated S3 bucket, IAM role, storage
credential, and external location) and their schemas. Does **not** create or assign a Unity
Catalog metastore — most Databricks accounts already have one auto-provisioned and
auto-assigned per region (confirm with `databricks account metastores list --profile ACCOUNT`
and `databricks metastores current`); if this account genuinely has none, that's a distinct,
one-time account-level setup this skill doesn't cover.

## Key difference from `5.1-create-workspace`: workspace-scoped, not account-scoped

`5.1`'s resources (the workspace itself, its cross-account IAM role) are **account**-scoped —
they use the `databricks.mws` aliased provider, because creating a workspace is an operation
against `accounts.cloud.databricks.com`. Catalogs, schemas, storage credentials, and external
locations are **workspace**-scoped — they use the plain **default** `databricks` provider in
`providers.tf` (the one already configured via `databricks_host`/`databricks_profile` locally,
or `TF_VAR_databricks_host` in CI), because Unity Catalog's REST API operates against one
specific workspace. Concretely:

- `modules/catalog` needs no `configuration_aliases` in its `versions.tf` and the root
  `catalogs.tf` module call needs no `providers = {}` block — simpler than `modules/workspace`
  on both counts.
- **Catalogs land in whichever workspace the default `databricks` provider currently targets.**
  This is a real, easy-to-miss gotcha: if `providers.tf`'s default connection points at a
  different workspace than the one you intend, catalogs get created there instead, silently.
  Always confirm `databricks_host`/`databricks_profile` (local) or the `DATABRICKS_HOST` repo
  variable (CI) before running this — see "Before starting."
- `deploy.sh` only needs ordinary workspace-level Databricks auth (`3.2.2-authenticate-databricks`)
  — no account-admin OAuth login dance like `5.1`'s deploy.sh, since nothing here is an
  account-level operation.

## Before starting

- Run `3.2-check-prerequisites` and `4.1-check-cicd-prerequisites` (or confirm both already
  passed).
- Confirm `account.auto.tfvars` exists (from `5.1-create-workspace`'s Phase 1) —
  `databricks_account_id` is shared and reused from there, not re-gathered here.
- **Confirm which workspace the default `databricks` provider targets**, and that it's the one
  you actually want these catalogs in: check `databricks_profile` in `terraform.tfvars` (local)
  and the `DATABRICKS_HOST` GitHub repo variable (CI). If it needs to change, that's a one-time
  fix outside this skill's scope (repoint `providers.tf`'s target — e.g. via a new named
  `databricks auth login --profile <name>` and updating `databricks_profile`/`DATABRICKS_HOST`
  accordingly), not something this skill's `implement.sh`/`deploy.sh` do.
- Confirm at least one workspace exists and is `RUNNING` (via `5.1-create-workspace` or
  otherwise) — Unity Catalog needs a live workspace to attach to.

## Phase 1: Gather details

Ask the user for these before touching any file:

- **A short catalog slug/name** (e.g. `analytics`) — used as the `catalogs` map key and the
  actual catalog name.
- **Comment** (optional) describing the catalog's purpose.
- **Root S3 bucket name** for this catalog's external storage — must be globally unique across
  **all of S3**. Suggest `<catalog-slug>-uc-storage-<random-suffix>` and confirm.
- **Storage credential / IAM role name** — suggest a default
  (`databricks-uc-<catalog-slug>-storage`), confirmable.
- **Schema names** to create inside the catalog (a list; can be empty and added later by editing
  the same map entry).
- **Confirm the AWS identity**: run `aws sts get-caller-identity`, same rationale as `5.1` — the
  new IAM role/bucket land in whichever AWS account this resolves to.

Once confirmed, write the entry into `databricks/infrastructure/catalogs.auto.tfvars` (create
the file if it doesn't exist yet — no `.example` to copy from; the shape is documented here and
in `modules/catalog/variables.tf`'s own descriptions). This file is **committed, not
gitignored** — none of this data is secret.

## Phase 2: Implement

```
bash .claude/skills/05-databricks-terraform-deployment/5.2-create-unity-catalog/implement.sh
```

Idempotent — scaffolds `modules/catalog/{versions,variables,main,outputs}.tf`, root
`catalogs.tf` (the `for_each` module block), the `catalogs` variable in `variables.tf`, and
aggregated outputs in `outputs.tf`. Never overwrites a file that already exists, so **after the
first catalog, this step is a no-op**. Only writes generic resource/variable definitions, never
real values (those go into `catalogs.auto.tfvars`, handled directly per Phase 1).

Requires `account.auto.tfvars` to already exist (errors out with a pointer to
`5.1-create-workspace` if not) — `databricks_account_id` is reused from there as the storage
credential IAM role's `external_id`, the same idiom `5.1`'s cross-account role already uses.

Uses the `databricks` provider's own `databricks_aws_unity_catalog_assume_role_policy` and
`databricks_aws_unity_catalog_policy` data sources — the Unity-Catalog-specific analogues of the
`databricks_aws_*` data sources `5.1`'s module uses for its cross-account role — to generate the
IAM trust/permissions policies, rather than hand-maintained policy JSON.

## Phase 3: Deploy

Same two options as `5.1`, same discipline (never auto-apply, human reviews the plan first):

**A. Through the CI/CD pipeline** — commit whatever Phase 2 scaffolded (first catalog only) plus
the Phase 1 edit to `catalogs.auto.tfvars`, push, open a PR. `terraform-plan.yml` posts the plan
automatically — no repo-variable or workflow changes needed. Merging triggers
`terraform-apply.yml`.

**B. Directly, from this machine**:

```
bash .claude/skills/05-databricks-terraform-deployment/5.2-create-unity-catalog/deploy.sh plan
```

Checks ordinary workspace-level Databricks auth (not account-level — see "Key difference"
above), warns on any `bucket_name` in `catalogs.auto.tfvars` that's already reachable in S3,
then `terraform init` + `plan -out=tfplan`. Show the plan to the user and get explicit
confirmation — this creates real, billed AWS + Databricks infrastructure. Once confirmed:

```
bash .claude/skills/05-databricks-terraform-deployment/5.2-create-unity-catalog/deploy.sh apply
```

Applies exactly the reviewed `tfplan`, then prints `catalog_names` / `catalog_external_location_urls`
/ `catalog_schema_full_names` (maps keyed by each catalog's slug).

## Adding catalog #2 and beyond

Once the module exists (Phase 2 has run once), adding another catalog is: Phase 1's
conversation again, add a new entry to the already-existing `catalogs.auto.tfvars`, then Phase 3
as usual. `implement.sh` has nothing left to do (confirm it reports "Nothing to do"). No
`.github/workflows/*.yml` edit and no `gh variable set` at any point, for any number of catalogs.

## Known IAM propagation delay

Same class of issue as `5.1`'s workspace cross-account role: `databricks_storage_credential` can
fail on `apply` with a credential-validation error even though the IAM role/policy were just
created successfully, because Databricks validates the role by actually assuming it and IAM is
eventually consistent. `modules/catalog/main.tf` includes a `time_sleep.iam_propagation`
resource (30s) that the storage credential depends on. If it still fails, the role/policy are
already in state — re-run `deploy.sh plan` then `deploy.sh apply` again, nothing needs to be
recreated.

## Constraints

- Never creates or assigns a metastore — assumes one already exists and is assigned to the
  target workspace. Say so rather than improvising metastore-creation resources if the user's
  account genuinely doesn't have one yet; that's a distinct, one-time account-level task.
- Never applies without a human-reviewed `plan` step first, whether local (`deploy.sh apply`
  hard-refuses without a saved `tfplan`) or via the pipeline.
- Never guesses or silently defaults the bucket name, catalog name, or which AWS identity is
  active — always confirmed with the user in Phase 1.
- Never guesses which workspace catalogs land in — always confirm the default provider's target
  first (see "Before starting"); this is the one gotcha specific to this skill that `5.1` didn't
  have to worry about.
- `implement.sh` never overwrites existing files and never writes real per-catalog values —
  those only ever go into the committed `catalogs.auto.tfvars`, directly, per Phase 1.
- `bucket_force_destroy` defaults to `false` in each map entry — only set `true` if the user
  explicitly wants easy teardown of a disposable/test catalog.
- Each catalog gets its own dedicated bucket + IAM role + storage credential (not a shared
  credential across catalogs) — matches `modules/workspace`'s self-containment. If the user
  wants a shared credential/bucket across multiple catalogs later, that's a variation to design
  separately, not this module's default behavior.
