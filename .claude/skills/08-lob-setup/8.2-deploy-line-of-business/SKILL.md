---
name: 8.2-deploy-line-of-business
description: Deploy the real catalog for a line of business that 8.1-discover-line-of-business just added -- update the unit's existing pattern<NN>_units.auto.tfvars entry (setting workspace.host to the real URL if it's still null, and adding the new catalog to its catalogs map), then submit via 4.5-open-terraform-pr. Never re-scaffolds the unit, never applies Terraform locally. Use when the user wants to actually create the real catalog for a newly-added line of business (or a flat unit's first catalog).
---

# Deploy line of business (databricks repo)

Second skill in the `08-lob-setup` group — see [../README.md](../README.md). Consumes
`8.1-discover-line-of-business`'s output; hands off to `4.5-open-terraform-pr`
(`04-github-cicd` group).

**Scope**: a catalogs-only edit to one specific (business unit × environment tier) unit's
*already-existing* `pattern<NN>_units.auto.tfvars` entry (`unit_key` = `<bu_key>_<env>`, e.g.
`flightops_dev`) — the "catalogs follow-up" half of `6.4-deploy-organization`'s (and
`7.2-deploy-business-unit`'s) two-phase reality, scoped to one new catalog rather than a unit's
whole initial set. A LOB needed across more than one tier of the same BU means running this skill
once per tier's own `unit_key`. Never touches the unit's scaffolded
`pattern<NN>_units_<unit_key>.tf` file itself, and never runs `terraform apply`.

## Before starting

- Require the unit to already have a scaffolded `pattern<NN>_units_<unit_key>.tf` **and** a
  `pattern<NN>_units.auto.tfvars` entry (from `7.2-deploy-business-unit`, or `6.4`) — if not, point
  at `07-business-unit-setup`/`6.4-deploy-organization` instead; this skill never creates a unit.
- Confirm `4.1-check-cicd-prerequisites` passes (or already confirmed).
- Get the unit's real workspace URL (`terraform output workspace_urls`, or the Account Console) if
  its current tfvars entry still has `workspace.host = null` — needed either way, whether this is
  the unit's very first catalog or a later one.

## Phase 1: Update the tfvars entry

In this unit's existing `pattern<NN>_units.auto.tfvars` entry:

- Set `workspace.host` to the real URL — **only if it's still `null`**; never overwrite an
  already-set host without the user confirming why it should change.
- Add the new catalog to this entry's `catalogs` map: key per `docs/naming-conventions.md` (domain
  = unit key, subdomain = LOB key; domain-only if this is a flat unit's catalog), with
  `bucket_name`, `schemas`, and `reader_emails`/`writer_emails`/`owner_emails` from `8.1`'s mapping.

## Phase 2: Submit

Invoke `4.5-open-terraform-pr`:

- **Branch name**: `infra/<pattern>-unit-<unit_key>-catalog-<catalog_key>` (e.g.
  `infra/01-pattern-unit-flightops-dev-catalog-dev_flightops_crew_ops`).
- **Commit message / PR title**: "Add `<catalog_key>` catalog to `<unit_key>`" — not a generic
  placeholder.
- **PR body**: reference `8.1`'s `databricks-mapping.md` row this covers, and note if this is the
  unit's very first catalog (i.e. also the PR that finally sets a real `workspace.host`).

Get the PR URL back before continuing.

## Phase 3: Record

Update `databricks-mapping.md`'s row for this catalog with the PR URL.

## Constraints

- Never touches a unit whose workspace isn't confirmed `RUNNING` (per `8.1`'s check) — re-confirm
  if picking this skill up in a fresh session rather than trusting a stale answer.
- Never fabricates `workspace.host` — get it from `terraform output`/the Account Console, or stop
  and ask.
- Never overwrites an already-set `workspace.host` with a different value without the user
  confirming why.
- Never applies Terraform locally.
- Never re-scaffolds or hand-edits `pattern<NN>_units_<unit_key>.tf` for this — the catalog change
  is a pure `pattern<NN>_units.auto.tfvars` edit, no code-generation step needed (unlike a
  brand-new unit's `add-pattern<NN>-unit.sh`).
- Never assumes `01-pattern`'s specific file/variable names apply to a different org without
  checking that org's own `pattern-definition.md` first.
- Never checks off or marks anything "done" before `4.5-open-terraform-pr` has actually returned a
  PR URL for it.
