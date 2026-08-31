---
name: 9.1-discover-environment
description: Confirm (and, if it wasn't already requested, add) a new environment tier for a business unit or shared department that already exists and already has at least one lower tier deployed -- verify dev-before-stg-before-prod ordering against what's actually deployed, then update org-structure.yaml (if the tier is new to that unit's environments list) and databricks-mapping.md with the tier's planned workspace. Does not touch lines of business (see 08-lob-setup) and does not edit any Terraform file. Use when the user wants to promote an existing business unit to a new environment tier (e.g. give a dev-only unit a stg or prod workspace too).
---

# Discover environment (databricks repo)

First skill in the `09-environment-setup` group — see [../README.md](../README.md). Produces the
tier entry that `9.2-deploy-environment` then actually creates a workspace for.

**Scope**: confirms one new environment tier for a unit that's *already established and already
has a lower tier deployed*. Never creates the business unit itself (that's
`07-business-unit-setup`, or `06-organization-setup` for a unit from the org's original rollout)
and never decides pattern/catalog shape from scratch — inherited as-is from that org's existing
`databricks-mapping.md`/`pattern-definition.md`. Never asks about lines of business, and never
touches Terraform.

## Before starting

- Require `org-structure.yaml` and `databricks-mapping.md` to already exist for the target org, and
  the target business unit/department to already appear in both (from `6.1`/`6.2`, or `7.1`). If the
  unit itself doesn't exist yet, stop and point at `07-business-unit-setup` instead of inventing it
  here.
- Read the org's `pattern-definition.md` for this unit's shape rules — same mechanical application
  as `6.2`/`7.1`, no variation invented for this one tier.
- Check which of this unit's tiers already have a scaffolded `pattern<NN>_units_<unit_key>.tf`
  (`<bu_key>_<env>`) under `databricks/infrastructure/`, and whether each deployed one has actually
  merged and applied (not just an open PR) — `terraform output workspace_urls` / the Account
  Console, or ask the user. This is the real state `9.1` validates ordering against, not just
  `org-structure.yaml`'s stated `environments` list, which can include tiers that were requested but
  never actually built.

## Phase 1: Confirm the target tier

1. **Which tier?** Ask which new environment tier this unit should get next. If it's already in
   this unit's `org-structure.yaml` `environments` list, this is just "deploy the one that's still
   missing." If it isn't, this is a genuine scope change — confirm the user actually wants to
   expand this unit's environment footprint (mirrors `6.1` item 9's per-unit environments pass, one
   unit at a time, same `AskUserQuestion` discipline) before recording it.
2. **Region**, only if the org has more than one region in scope and this tier needs one other than
   the org's `environment_regions[<tier>]` default — record as a `region_overrides` entry on this
   unit, same as `7.1` item 4.
3. **Ordering check — don't ask, verify**: every tier *lower* than the requested one that this unit
   needs must already be deployed (merged + applied, `RUNNING`), per "Before starting"'s real-state
   check. If a lower tier is still only planned, or its PR is open but unmerged, **stop** and say so
   — don't let the user skip ahead to `stg`/`prod` before `dev` (or `stg`) is real infrastructure,
   same rule `6.3`'s Phase 1 rule 2 enforces for a whole-org rollout.

## Phase 2: Update org-structure.yaml

If the tier wasn't already in this unit's `environments` list, append it there now (same entry,
same unit — this is additive, not a new `business_units`/`shared_departments` entry). Add a
`region_overrides` entry only if Phase 1 item 2 surfaced one.

## Phase 3: Update databricks-mapping.md

Update this unit's row (or add one, depending on that doc's table shape) with the new tier's
planned workspace name (`<bu_key>-<env>`), catalogs column reading "none yet — via
`08-lob-setup`," groups/grants "pending catalogs." State the real infra count this adds (one more
workspace, plus a DR standby if `org-structure.yaml`'s `dr` block covers this tier) before
finishing.

## Constraints

- Never invents a tier the user didn't confirm wanting — a tier missing from `org-structure.yaml`
  is a real scope question (Phase 1 item 1), not something to add silently just because it would be
  "the natural next one."
- Never lets a higher tier jump ahead of a lower one that isn't actually deployed yet — verify
  against real repo/Terraform state (scaffolded files, `terraform output`, open PRs), not just
  `org-structure.yaml`'s stated list, which can lag reality.
- Never adds a `lines_of_business` entry for this tier — that's `08-lob-setup`'s job, and it never
  carries over automatically from a lower tier's catalogs; each tier's catalogs are created there
  independently.
- Never writes to any `*.auto.tfvars` file or runs any scaffold script — this skill only edits
  `org-structure.yaml`/`databricks-mapping.md`; `9.2-deploy-environment` makes the real edit.
- Never decides or changes the org's pattern — inherited as-is; if it genuinely doesn't fit, that's
  a `6.2` conversation, not something to route around here.
