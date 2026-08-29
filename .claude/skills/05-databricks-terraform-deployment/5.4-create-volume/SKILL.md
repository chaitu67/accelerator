---
name: 5.4-create-volume
description: Create Unity Catalog volumes (MANAGED or EXTERNAL) inside an existing catalog/schema, via a shared modules/volume Terraform module instantiated per-volume from a committed volumes.auto.tfvars map -- gathers details, scaffolds the module (once), then deploys (plan, review, apply). Adding a second (or Nth) volume never requires touching CI workflow files or GitHub repo variables -- only this one committed tfvars file changes. Use when the user asks to create a Unity Catalog volume for file/non-tabular storage.
---

# Create Unity Catalog Volume (databricks repo)

Fourth skill in the `05-databricks-terraform-deployment` group, alongside
[5.1-create-workspace](../5.1-create-workspace/SKILL.md),
[5.2-create-unity-catalog](../5.2-create-unity-catalog/SKILL.md), and
[5.3-manage-catalog-access](../5.3-manage-catalog-access/SKILL.md) — see [../README.md](../README.md).
Same standing pattern (reusable module + `for_each` + committed `*.auto.tfvars`, no CI edits per
instance), applied to Unity Catalog volumes.

**Scope**: creates one `databricks_volume` per entry — a Unity Catalog object for storing and
accessing non-tabular files (arbitrary files, model artifacts, images, etc.) inside an existing
catalog/schema. Does **not** create the catalog or schema themselves (that's `5.2`), and does
**not** grant anyone privileges on the volume (that's `5.3` territory, extended to
volume-securables if a group needs `READ VOLUME`/`WRITE VOLUME` later — see "Known gap" below).

## MANAGED vs. EXTERNAL — pick one per volume

- **MANAGED** (default, the common case): Databricks stores the volume's files under the owning
  schema's own managed storage location automatically. No bucket, IAM role, or storage credential
  to provision — `modules/volume` just declares the `databricks_volume` resource.
- **EXTERNAL**: `storage_location` must point at an S3 path already covered by a *registered*
  external location's storage credential — Unity Catalog validates this at apply time by path
  prefix, not by requiring a dedicated external location per volume. This skill does **not**
  provision a new bucket/IAM role/external location per volume (unlike `5.2`'s one-per-catalog
  pattern) — root `volumes.tf` defaults an EXTERNAL volume's `storage_location` to a subpath under
  its *own catalog's* existing external location (`module.catalog[...].external_location_url`),
  since that credential already grants access there. An explicit `storage_location` is only needed
  to point a volume at a genuinely different, already-registered external location — if the user
  wants that, confirm the target location is already registered and its credential actually covers
  the given path; this skill has no way to create a new one itself.
- Ask the user which they want — don't default to EXTERNAL "for flexibility." MANAGED is simpler
  and sufficient unless the user has a specific reason to control the exact bucket/path (e.g.
  pre-existing files to mount, or a compliance requirement for a specific bucket).

## Known gap: this does not grant volume access

Creating a volume does not by itself let anyone other than a workspace admin read or write files
in it. Unity Catalog privilege grants on volumes (`READ VOLUME`, `WRITE VOLUME`) via
`databricks_grants` are a distinct securable type from the catalog/schema grants `5.3` already
builds — `5.3`'s `catalog_access.tf` only ever sets `catalog` or `schema` on `databricks_grants`,
never `volume`. Extending `5.3` (or this skill) to grant volume-level privileges is a real,
not-yet-built extension — say so plainly rather than assuming a volume is usable the moment it
exists.

## Before starting

- Run `3.2-check-prerequisites` and `4.1-check-cicd-prerequisites` (or confirm both already
  passed).
- Confirm at least one catalog already exists via `5.2-create-unity-catalog` — a volume needs a
  real `catalogs.auto.tfvars` entry to attach to (`modules/catalog` must already be scaffolded).
- Confirm the same workspace-targeting question `5.2` asks has already been answered and still
  holds (volumes land against whichever workspace the default `databricks` provider currently
  targets, same as catalogs and grants) — don't re-ask if `5.2`/`5.3` was just run in this same
  conversation and nothing changed.

## Phase 1: Gather details

Ask the user for these before touching any file:

- **Which catalog** this volume belongs to (must already have an entry in `catalogs.auto.tfvars`
  via `5.2`).
- **Which schema** within that catalog (must already exist in that catalog's `schemas` list).
- **A volume name.** Only needs to be unique within `catalog.schema`, not globally, but **must**
  follow `../../../../databricks/docs/naming-conventions.md`'s volume pattern:
  `<purpose>[_<subtype>]` (lowercase, starts with a letter, underscore-separated — e.g.
  `raw_files`, `model_artifacts`) — enforced by a Terraform `validation` block on `var.volumes`
  (unconditionally, no dev/stg/prod carve-out, since volumes have no `environment` field of their
  own), so a non-matching name fails at `terraform plan`, not just in this conversation. Don't
  silently rename what the user asked for to make it compliant — show them the pattern and ask for
  a compliant name instead. Suggest the map-entry slug doubles as the name unless the user wants
  them to differ (e.g. slug `analytics-model-artifacts`, real name `model_artifacts`); the
  validation checks whichever one is effective (`name` if set, else the slug).
- **MANAGED or EXTERNAL** — see the section above; ask, don't default silently.
- **If EXTERNAL and the user wants a non-default location**: the exact `storage_location` S3 URL,
  and confirm it's already covered by a registered external location's credential (check
  `databricks_host`'s workspace under Catalog Explorer → External Locations, or
  `databricks external-locations list --profile <profile>`) — otherwise leave `storage_location`
  unset and let it default under the owning catalog's own external location.
- **Comment** (optional) describing the volume's purpose.

Once confirmed, write the entry into `databricks/infrastructure/volumes.auto.tfvars` (create the
file if it doesn't exist yet — no `.example` to copy from; the shape is documented here and in
`modules/volume/variables.tf`'s own descriptions, plus the `volumes` variable in the root
`variables.tf`). This file is **committed, not gitignored** — none of this data is secret.

## Phase 2: Implement

```
bash .claude/skills/05-databricks-terraform-deployment/5.4-create-volume/implement.sh
```

Idempotent — scaffolds `modules/volume/{versions,variables,main,outputs}.tf`, root `volumes.tf`
(the `for_each` module block), the `volumes` variable in `variables.tf`, and aggregated outputs in
`outputs.tf`. Never overwrites a file that already exists, so **after the first volume, this step
is a no-op**. Only writes generic resource/variable definitions, never real values (those go into
`volumes.auto.tfvars`, handled directly per Phase 1).

Requires `modules/catalog/main.tf` to already exist (errors out with a pointer to
`5.2-create-unity-catalog` if not) — `volumes.tf` references `module.catalog[...]` outputs
directly (both for the parent `catalog_name` and for deriving a default EXTERNAL
`storage_location`).

## Phase 3: Deploy

Same two options as `5.1`/`5.2`/`5.3`, same discipline (never auto-apply, human reviews the plan
first):

**A. Through the CI/CD pipeline** — commit whatever Phase 2 scaffolded (first volume only) plus
the Phase 1 edit to `volumes.auto.tfvars`, push, open a PR. `terraform-plan.yml` posts the plan
automatically — no repo-variable or workflow changes needed. Merging triggers
`terraform-apply.yml`.

**B. Directly, from this machine**:

```
bash .claude/skills/05-databricks-terraform-deployment/5.4-create-volume/deploy.sh plan
```

Checks ordinary workspace-level Databricks auth (not account-level — volumes are workspace-scoped,
same as `5.2`'s catalogs), then `terraform init` + `plan -out=tfplan`. Show the plan to the user
and get explicit confirmation. Once confirmed:

```
bash .claude/skills/05-databricks-terraform-deployment/5.4-create-volume/deploy.sh apply
```

Applies exactly the reviewed `tfplan`, then prints `volume_full_names` / `volume_storage_locations`
(maps keyed by each volume's slug).

## Adding volume #2 and beyond

Once the module exists (Phase 2 has run once), adding another volume is: Phase 1's conversation
again, add a new entry to the already-existing `volumes.auto.tfvars`, then Phase 3 as usual.
`implement.sh` has nothing left to do (confirm it reports "Nothing to do"). No
`.github/workflows/*.yml` edit and no `gh variable set` at any point, for any number of volumes.

## Constraints

- Never creates the owning catalog or schema — both must already exist via `5.2`. Say so rather
  than improvising catalog/schema-creation resources here.
- Never grants anyone read/write privileges on the volume — see "Known gap" above.
- Never applies without a human-reviewed `plan` step first, whether local (`deploy.sh apply` hard-
  refuses without a saved `tfplan`) or via the pipeline.
- Never guesses which catalog/schema a volume attaches to, or MANAGED vs. EXTERNAL — always
  confirmed with the user in Phase 1.
- For EXTERNAL volumes, never invents a `storage_location` outside what's already covered by a
  registered external location's credential — if the user wants a genuinely new bucket/credential
  dedicated to this volume, that's a `5.2`-style per-catalog storage-credential setup applied to a
  volume instead, a distinct design this skill doesn't build; flag it rather than improvising.
- `implement.sh` never overwrites existing files and never writes real per-volume values — those
  only ever go into the committed `volumes.auto.tfvars`, directly, per Phase 1.
- Never guesses which workspace volumes land in — same rule as `5.2`/`5.3`, not re-derived here.
- Never accepts a non-compliant volume name and proceeds anyway — the Terraform `validation` block
  on `var.volumes` will reject it at `plan` time regardless (unconditionally, for every volume, not
  just prod). See `databricks/docs/naming-conventions.md`.
