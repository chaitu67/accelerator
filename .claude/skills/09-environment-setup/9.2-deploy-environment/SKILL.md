---
name: 9.2-deploy-environment
description: Deploy the real workspace for a business unit's next environment tier that 9.1-discover-environment just confirmed -- run the org's pattern's add-pattern<NN>-unit.sh scaffold for that tier's own unit_key (<bu_key>_<env>), add its workspace-only pattern<NN>_units.auto.tfvars entry (host null, catalogs {}), and submit via 4.5-open-terraform-pr. Never applies Terraform locally, never bundles catalogs into this PR -- that's 08-lob-setup's job, run once per existing LOB, once this tier is RUNNING. Use when the user wants to actually create the real workspace for a business unit's next environment tier.
---

# Deploy environment (databricks repo)

Second skill in the `09-environment-setup` group — see [../README.md](../README.md). Consumes
`9.1-discover-environment`'s output; hands off to `4.5-open-terraform-pr` (`04-github-cicd` group).

**Scope**: workspace only, for exactly one (business unit × environment tier) — the tier
`9.1` just confirmed. This is the same mechanism `7.2-deploy-business-unit` uses for a unit's
*first* tier, applied here to a *later* one instead: its own `unit_key` (`<bu_key>_<env>`), own
scaffolded file, own `pattern<NN>_units.auto.tfvars` entry — never a second tier bundled into an
existing one. Never creates this tier's catalogs (see `08-lob-setup`) and never runs
`terraform apply`.

## Before starting

- Require `9.1-discover-environment` to have already confirmed this tier (in `org-structure.yaml`'s
  `environments` list for the unit) and verified every lower tier is already deployed — re-check
  real state yourself (scaffolded files under `databricks/infrastructure/`, `terraform output
  workspace_urls`, open PRs via `gh pr list`) rather than trusting a stale plan; a prior `9.1`/`9.2`
  run (this session or an earlier one) may have already submitted this tier in a PR still awaiting
  review/merge.
- Confirm no `pattern<NN>_units_<unit_key>.tf` already exists for this tier's `<bu_key>_<env>` — if
  it does, this tier is already deployed or mid-flight; nothing for this skill to do, point at
  `08-lob-setup` for its catalogs instead.
- Confirm `4.1-check-cicd-prerequisites` passes (or already confirmed).
- Read the org's `pattern-definition.md` for the exact mechanism names this org's pattern uses —
  don't assume `01-pattern`'s specific names apply without checking which pattern this org actually
  uses.

## Phase 1: Scaffold

Run `add-pattern<NN>-unit.sh <bu_key>_<env>` for this tier (e.g. `flightops_stg`) — idempotent;
confirm it actually scaffolded something.

## Phase 2: Add the tfvars entry

Add this `<bu_key>_<env>` unit_key's entry to `pattern<NN>_units.auto.tfvars`:

- `workspace = {...}`: `display_name` (`<bu_key>-<env>`, e.g. `flightops-stg`), `aws_region` (from
  `org-structure.yaml`'s `environment_regions[<env>]` or this unit's own
  `region_overrides[<env>]`), `root_bucket`, `admin_emails`, and any other field that pattern's
  module schema calls for — from `9.1`'s `databricks-mapping.md` row.
- `host = null` — never fabricate a placeholder URL.
- `catalogs = {}` — deliberately empty; this tier's LOB catalogs (even a flat unit's one
  domain-only catalog) are `08-lob-setup`'s job, and don't carry over automatically from the lower
  tier's catalogs — each tier's catalogs are independent Unity Catalog objects.

If `org-structure.yaml`'s `dr` block covers this tier, also add its workspace-only DR-standby entry
(`<bu_key>_<env>_dr`, `aws_region = dr.region`, `catalogs = {}` permanently).

## Phase 3: Submit

Invoke `4.5-open-terraform-pr`:

- **Branch name**: `infra/<pattern>-unit-<bu_key>-<env>` (e.g. `infra/01-pattern-unit-flightops-stg`).
- **Commit message / PR title**: "Create `<bu_key>_<env>` `<pattern>` unit workspace" — not a
  generic placeholder.
- **PR body**: reference `9.1`'s `databricks-mapping.md` row this covers, note this is a
  workspace-only PR for an existing unit's next tier, and that its LOB catalogs are a separate,
  later `08-lob-setup` follow-up (one run per existing LOB).

Get the PR URL back before continuing.

## Phase 4: Record

Update `databricks-mapping.md`'s row for this tier with the PR URL. Once merged, applied, and the
workspace reports `RUNNING`, run `08-lob-setup` once per this unit's existing LOB (or once, flat,
for a no-LOB-split unit) to populate this tier's catalogs — they don't exist yet, even though the
same LOBs already have catalogs at this unit's lower tier(s).

## Constraints

- Never deploys a tier `9.1` hasn't confirmed, and never deploys one whose lower tier(s) aren't
  actually deployed yet (merged + applied) — re-verify real state, don't trust a stale plan.
- Never bundles catalogs into this PR — always `workspace` + `host = null` + `catalogs = {}` only.
- Never applies Terraform locally.
- Never fabricates `workspace.host` — always `null` in this skill's PR.
- Never re-scaffolds a `unit_key` whose `pattern<NN>_units_<unit_key>.tf` already exists.
- Never hand-edits `pattern<NN>_units_<unit_key>.tf` beyond what the scaffold produces.
- Never assumes `01-pattern`'s specific file/variable names apply to a different org without
  checking that org's own `pattern-definition.md` first.
- Never checks off or marks anything "done" before `4.5-open-terraform-pr` has actually returned a
  PR URL for it.
