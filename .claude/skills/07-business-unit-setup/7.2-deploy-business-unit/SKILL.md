---
name: 7.2-deploy-business-unit
description: Deploy the real workspace for the FIRST (lowest) environment tier of a business unit or shared department that 7.1-discover-business-unit just added to org-structure.yaml/databricks-mapping.md -- run the org's pattern's add-pattern<NN>-unit.sh scaffold for that tier's own unit_key (<bu_key>_<env>), add its workspace-only pattern<NN>_units.auto.tfvars entry (host null, catalogs {}), and submit via 4.5-open-terraform-pr. Additional tiers for the same unit go through 09-environment-setup afterward, never this skill again. Never applies Terraform locally, never bundles catalogs into this PR -- that's 08-lob-setup's job once the workspace is RUNNING. Use when the user wants to actually create the real, first workspace for a newly-added business unit.
---

# Deploy business unit (databricks repo)

Second skill in the `07-business-unit-setup` group — see [../README.md](../README.md). Consumes
`7.1-discover-business-unit`'s output; hands off to `4.5-open-terraform-pr`
(`04-github-cicd` group) for the actual commit/push/PR mechanics.

**Scope**: workspace only, and only the unit's **first** (lowest) environment tier. Under
`01-pattern` (and any pattern with dedicated per-unit workspaces), each (business unit ×
environment tier) pair is its own separate Terraform unit — its own `unit_key`, own workspace, own
scaffolded file (see `7.1`'s "Terraform unit granularity" note). This skill only ever creates the
**first** one for a brand-new unit; every later tier for that same business unit is
`09-environment-setup`'s job, not a second run of this skill. This is the same "brand-new unit,
workspace-only" mechanism `6.4-deploy-organization` Phase 2 already defines for a whole-org
rollout, invoked directly here for one incrementally-added unit's first tier instead of picked off
a whole-org `deployment-plan.md`. It never creates this unit's catalogs (see `08-lob-setup`) and
never runs `terraform apply`.

## Before starting

- Require the business unit to already exist in `org-structure.yaml`/`databricks-mapping.md` (from
  `7.1`), and confirm **no** tier of it has a scaffolded `pattern<NN>_units_<unit_key>.tf` yet under
  `databricks/infrastructure/` for any `<bu_key>_<env>` — if one already exists, this unit already
  has at least one tier deployed (or mid-flight); this skill only handles a unit's very first tier,
  point at `09-environment-setup` for an additional one instead.
- Pick the **first tier to deploy**: the lowest tier in `docs/naming-conventions.md`'s ordering
  (`dev` < `stg` < `prod`) among this unit's requested `environments` in `org-structure.yaml` — never
  start with `stg`/`prod` while `dev` (or `stg`, if the unit uses one) is still unbuilt.
- Confirm `4.1-check-cicd-prerequisites` passes (or already confirmed) — `4.5-open-terraform-pr`
  assumes the pipeline it submits into already exists.
- Read the org's `pattern-definition.md` (one level up from its own `docs/organization/<NN>-pattern/<org-slug>/`
  folder) for the exact mechanism names this org's pattern uses — its Terraform module, its scaffold
  script (`add-pattern<NN>-unit.sh`), its unit-data variable (`pattern<NN>_units.auto.tfvars`). Don't
  assume `01-pattern`'s specific names apply without checking which pattern this org actually uses.

## Phase 1: Scaffold

Run `add-pattern<NN>-unit.sh <bu_key>_<env>` for the chosen first tier (e.g. `flightops_dev`) —
idempotent; confirm it actually scaffolded something, not "Nothing to do" for a unit expected to be
brand new.

## Phase 2: Add the tfvars entry

Add this `<bu_key>_<env>` unit_key's entry to `pattern<NN>_units.auto.tfvars`:

- `workspace = {...}` populated from `7.1`'s `databricks-mapping.md` row: `display_name`
  (`<bu_key>-<env>`, e.g. `flightops-dev`), `aws_region` (from `org-structure.yaml`'s
  `environment_regions[<env>]` or this unit's own `region_overrides[<env>]`), `root_bucket`,
  `admin_emails`, and any other field that pattern's module schema calls for.
- `host = null` — nothing references it yet, since `catalogs` is empty; never fabricate a
  placeholder URL.
- `catalogs = {}` — deliberately empty, even for a unit the mapping says will end up flat
  (no LOB split). Its one domain-only catalog is still `08-lob-setup`'s job.

If `org-structure.yaml`'s `dr` block covers this tier, also add its workspace-only DR-standby entry
(`<bu_key>_<env>_dr`, `aws_region = dr.region`, `catalogs = {}` permanently) — same as
`6.2-map-databricks-pattern` Phase 2 would for a whole-org rollout.

## Phase 3: Submit

Invoke `4.5-open-terraform-pr`:

- **Branch name**: `infra/<pattern>-unit-<bu_key>-<env>` (e.g. `infra/01-pattern-unit-flightops-dev`).
- **Commit message / PR title**: "Create `<bu_key>_<env>` `<pattern>` unit workspace" — not a
  generic placeholder.
- **PR body**: reference `7.1`'s `databricks-mapping.md` row this covers, and note explicitly that
  this is a workspace-only PR awaiting a catalogs follow-up via `08-lob-setup`, and that any
  additional environment tier for this same unit is a separate, later `09-environment-setup` run.

Get the PR URL back before continuing.

## Phase 4: Record

Update `databricks-mapping.md`'s row for this unit with the PR URL against its first tier's
workspace (e.g. "`flightops-dev`: PR #123, awaiting merge/apply"), and mark any remaining requested
tiers as "planned — via `09-environment-setup`, once this tier is deployed." Once merged, applied,
and the workspace reports `RUNNING`, the next step is `08-lob-setup` for this tier's first LOB
catalog — this tier has zero catalogs until that runs, even if the unit is meant to end up flat.

## Constraints

- Never deploys more than one (business unit × environment tier) per run — always the unit's first,
  lowest tier only; later tiers go through `09-environment-setup`.
- Never bundles catalogs into this PR — always `workspace` + `host = null` + `catalogs = {}` only,
  matching `6.4-deploy-organization`'s two-phase-reality rule.
- Never applies Terraform locally.
- Never fabricates `workspace.host` — always `null` in this skill's PR.
- Never re-scaffolds a `unit_key` whose `pattern<NN>_units_<unit_key>.tf` already exists — check
  first, per "Before starting."
- Never hand-edits `pattern<NN>_units_<unit_key>.tf` beyond what the scaffold produces — this
  skill's only edits are to `pattern<NN>_units.auto.tfvars` and `databricks-mapping.md`.
- Never assumes `01-pattern`'s specific file/variable names apply to a different org without
  checking that org's own `pattern-definition.md` first.
- Never checks off or marks anything "done" before `4.5-open-terraform-pr` has actually returned a
  PR URL for it.
