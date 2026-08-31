---
name: 7.1-discover-business-unit
description: Interview the user, one AskUserQuestion pop-up at a time, to add ONE new business unit or shared department to an org whose overall structure is already discovered and mapped to a pattern (org-structure.yaml and databricks-mapping.md must already exist for it). Adds a business_units (or shared_departments) entry to org-structure.yaml and a per-unit row to databricks-mapping.md, following 6.1/6.2's own schemas. Does not touch lines of business (see 08-lob-setup) and does not edit any Terraform file. Use when the user wants to add a new business unit or department to an org that's already been set up.
---

# Discover business unit (databricks repo)

First skill in the `07-business-unit-setup` group — see [../README.md](../README.md). Produces the
unit entry that `7.2-deploy-business-unit` then actually creates a workspace for.

**Scope**: adds exactly one new unit to an *already-established* org's docs. Never discovers a
whole org from scratch (that's `6.1-discover-org-structure`) and never decides or changes which
pattern applies (that's `6.2-map-databricks-pattern` — this skill requires the pattern is already
chosen and reuses it as-is). Never asks about lines of business, and never touches Terraform.

## Before starting

- Require `org-structure.yaml` **and** `databricks-mapping.md` to already exist for the target org
  (`docs/organization/<NN>-pattern/<org-slug>/`). If more than one org's folder exists, ask which
  org this new unit belongs to rather than guessing. If either file is missing for that org, stop
  and point at `6.1-discover-org-structure`/`6.2-map-databricks-pattern` instead of inventing an
  org model or a pattern choice here.
- Read that org's pattern's own `pattern-definition.md`
  (`docs/organization/<NN>-pattern/pattern-definition.md`, one level up from the org's own
  subfolder) — apply its shape rules for a unit mechanically, same as `6.2` Phase 2 does. Don't
  invent a variation on it for this one new unit.
- Confirm the new unit's intended slug doesn't already exist among `org-structure.yaml`'s
  `business_units` or `shared_departments` keys.

## Terraform unit granularity: one workspace per (BU × environment tier)

`org-structure.yaml` records one entry per business unit/department, with a single `environments`
list — but under `01-pattern` (and any pattern with dedicated per-unit workspaces), each
environment tier that entry lists becomes its **own separate Terraform unit**: its own workspace,
its own `unit_key` (`<bu_key>_<env>`, e.g. `retail_dev`/`retail_stg`/`retail_prod`), its own
scaffold run, its own `pattern<NN>_units.auto.tfvars` entry — confirmed against
`meridian-financial/databricks-mapping.md`'s Section 1 (`retail-dev`, `retail-stg`, `retail-prod`
are three distinct workspaces). This skill's Phase 1 still gathers the *full* set of tiers a unit
will eventually need, all in one `org-structure.yaml` entry — but only `7.2-deploy-business-unit`
actually creates a workspace, and only for the **first** (lowest) tier; every additional tier for
that same unit is deployed later via `09-environment-setup`, one at a time, `dev` before `stg`
before `prod`.

## Phase 1: Gather the new unit

Same interview discipline as `6.1-discover-org-structure`: **one question at a time, via
`AskUserQuestion`, never as plain chat text**, illustrative examples + "Other" for open-ended
fields.

1. **Business unit or shared/cross-cutting department?** (mirrors `6.1` items 2 vs. 4 — a BU
   belongs to itself, a shared department needs access across other BUs' catalogs).
2. **Slug + display name.** Slug is lowercase, underscore-only, starts with a letter
   (`docs/naming-conventions.md`'s `domain` rules — no hyphens; they're not valid Unity Catalog
   identifier components).
3. **Which environment tiers this unit needs** — a subset of the org's own
   `organization.environment_tiers` (from `org-structure.yaml`), not necessarily all of them.
4. **Region override** — only ask if the org has more than one region in scope
   (`organization.regions`) and this unit might need a non-default one for some tier; skip the
   question entirely for a single-region org.
5. **Any data-sensitivity or isolation requirements** for this unit, same as `6.1` item 5 — record
   verbatim, flag PII/row-column-masking asks as not-yet-buildable rather than promising them.
6. **If this is a shared department**: which existing business units it needs access across. Every
   name given must already exist in `org-structure.yaml`'s `business_units` — if the user names one
   that isn't there, surface that rather than silently accepting it (they may mean a unit that
   itself needs `7.1` run for it first).

Don't ask about lines of business here at all — a brand-new unit always starts with zero catalogs;
`08-lob-setup` adds them afterward, one at a time, once the unit's workspace is real and `RUNNING`.

## Phase 2: Update org-structure.yaml

Append the new entry to `business_units` (or `shared_departments`), following
`6.1-discover-org-structure`'s Phase 2 schema exactly — same fields, same shape — with
`lines_of_business` omitted entirely (not an empty list; genuinely absent, same as any BU that
hasn't been given LOBs yet).

## Phase 3: Update databricks-mapping.md

Add one row to the per-unit table (`6.2-map-databricks-pattern`'s Phase 3 Section-1-style format):
the unit's key, its full list of requested environments, and its planned workspace name(s) — one
per tier, `<bu_key>-<env>` (e.g. `retail-dev`, `retail-stg`, `retail-prod`) — marked "planned, not
yet deployed" except the first, which `7.2-deploy-business-unit` is about to create. Catalogs
column reads "none yet — via `08-lob-setup`", groups/grants "pending catalogs," open gaps carried
over from Phase 1 item 5 if any.

State the real infra count this adds out loud (one workspace per environment tier this unit
needs, plus a DR standby if `org-structure.yaml`'s `dr` block covers one of its tiers) before
finishing — same discipline `6.2` Phase 2 already requires, just scoped to this one unit.

## Constraints

- Never invents a business unit or department the user didn't state.
- Never decides or changes the org's pattern — if the existing pattern's shape genuinely doesn't
  fit this new unit (e.g. it needs something `01-pattern` doesn't support), stop and say so; that's
  a `6.2` conversation, not something to route around here.
- Never adds a `lines_of_business` entry, even for a unit the user says will be flat — that
  omission is exactly what "no LOB split" already means; the unit's one domain-only catalog is
  still `08-lob-setup`'s job, not this skill's.
- Never writes to any `*.auto.tfvars` file or runs any scaffold script — this skill only edits
  `org-structure.yaml`/`databricks-mapping.md`; `7.2-deploy-business-unit` makes the real edit.
- Never records a shared department's scope referencing a business unit that doesn't already exist
  in `org-structure.yaml`.
- Never assigns this unit an environment tier the org itself doesn't have in
  `organization.environment_tiers`.
