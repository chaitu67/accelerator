---
name: 6.3-generate-deployment-plan
description: Turn a Databricks mapping (databricks-mapping.md, from 6.2-map-databricks-pattern, under docs/organization/<NN>-pattern/<org-slug>/) into an ordered, environment-by-environment deployment plan of concrete unit/catalog/grant/volume entries, each annotated with what realizes it (the org's pattern-specific scaffold + tfvars, or an independent-path 05.x skill) and its real cost/blast-radius. Writes deployment-plan.md alongside it. Use when the user has a Databricks mapping and wants a concrete, sequenced plan to actually build it.
---

# Generate deployment plan (databricks repo)

Third skill in the `06-organization-setup` group — see [../README.md](../README.md). Consumes
`6.2-map-databricks-pattern`'s output; hands off to `6.4-deploy-organization` for actual
execution.

**Scope**: this skill produces a plan document only — an ordered checklist of what to build, in
what order, via what mechanism. It never runs Terraform, never edits any `*.auto.tfvars` file, and
never invokes any scaffold script itself.

## Before starting

- Require `databricks-mapping.md` to exist under some `docs/organization/<NN>-pattern/<org-slug>/`
  folder (from `6.2-map-databricks-pattern`). If it doesn't, stop and point at `6.2` rather than
  inventing a mapping here. Note which pattern this org uses — everything below is scoped to that
  pattern's own mechanism (module, scaffold script, variable names), read from its
  `pattern-definition.md` one level up (`docs/organization/<NN>-pattern/pattern-definition.md` —
  pattern-level, not per-org) rather than assumed.
- Check the current state of the real Terraform project — read
  `databricks/infrastructure/pattern<NN>_units.auto.tfvars` (or the equivalent the pattern's
  definition names) and, for anything on the independent path,
  `workspaces.auto.tfvars`/`catalogs.auto.tfvars`/`groups.auto.tfvars`/`catalog_access.auto.tfvars`/
  `volumes.auto.tfvars`. The plan should only cover the **delta** between what's already deployed
  and what the mapping calls for — never re-list an already-existing unit/catalog/group as if it
  still needs creating.
- Check which `unit_key`s already have a scaffolded `pattern<NN>_units_<unit_key>.tf` versus which
  are brand new — an organization unit is realized via that pattern's own module + scaffold
  script, not the individual `5.1`/`5.2`/`5.3` skills; those stay reserved for the independent
  (non-organization) path, e.g. the existing `analytics` catalog.

## Phase 1: Sequence the delta

Ordering rules, in priority order:

1. **Per unit: scaffold before data before apply.** A brand-new `unit_key` needs that pattern's
   `add-pattern<NN>-unit.sh <unit_key>` run once (a real code addition — just the module block for a
   pattern like `01-pattern` with a self-contained per-unit provider, or a provider alias + module
   block for a pattern that declared its provider at the root instead — see its own
   `pattern-definition.md`) before its `pattern<NN>_units.auto.tfvars` entry (workspace + LOB
   catalogs + role emails, or whatever that pattern's shape calls for) means anything; the
   pattern's own module internally handles workspace-before-catalogs-before-groups-before-grants
   ordering for everything inside one unit, so the plan doesn't need to break a single unit's own
   resources into separate lines the way the independent path's `5.1`/`5.2`/`5.3`/`5.4` do.
2. **`dev` before `stg` before `prod`, per business unit** — never plan `prod` infra for a BU
   before that BU's `dev` (or `stg`, if it uses one) has actually been built and reviewed. This is
   the "environments must be used" requirement from this group's README: the plan is the
   enforcement point for build-lowest-tier-first.
3. **Shared/cross-cutting departments' grants come after every unit they touch, and are their own
   plan line.** For `01-pattern`, this is an `extra_grants` entry hand-added to the *target* unit's
   own `pattern<NN>_units_<unit_key>.tf` (see its `pattern-definition.md`) — not a separate
   freestanding file. A compliance department's grant on another BU's `prod` catalog can't be
   planned before both units' module calls exist and have run.

Within those constraints, order by whichever grouping makes review easiest for the user (usually:
one BU's full dev-through-prod stack at a time, rather than every BU's `dev` first).

## Phase 2: Annotate each entry

For every unit/catalog/grant/volume the mapping calls for, produce one plan line with:

- **What**: the exact intended name (following naming-conventions.md; call out any name still
  pending user confirmation from `6.2`).
- **Realized by**: for an organization unit, that pattern's `add-pattern<NN>-unit.sh` (new units
  only) plus its `pattern<NN>_units.auto.tfvars` entry; for a cross-unit grant, an `extra_grants`
  entry hand-added to the target unit's own `pattern<NN>_units_<unit_key>.tf` (per `01-pattern`'s
  design — a different pattern that declared its provider at the root instead would use a
  standalone `pattern<NN>_cross_grants.tf` file; check that pattern's own `pattern-definition.md`);
  for anything on the independent path (not part of any organization unit), the relevant `05.N-*`
  skill (`5.1-create-workspace`, `5.2-create-unity-catalog`, `5.3-manage-catalog-access`,
  `5.4-create-volume`).
- **Depends on**: the plan lines (if any) that must land first.
- **Blast radius**: `new real infra` (workspace — VPC/S3/IAM/compute billing), `new real storage`
  (catalog/volume — dedicated S3 bucket/IAM role), or `no new infra` (group, grant — Databricks
  account-level/metadata only, no cloud billing).
- **Open question**, if any, carried over verbatim from `6.2`'s mapping (e.g. an unresolved
  workspace-strategy tradeoff, a PII-masking gap).

## Phase 3: Write the plan

Write (or update) `deployment-plan.md` alongside the mapping doc, under the same
`docs/organization/<NN>-pattern/<org-slug>/` folder:

1. **Summary** — total new units / catalogs / groups / grants / volumes this plan adds, and the
   total count of items with `new real infra` blast radius (the number that matters for a cost
   conversation with the user before anything gets built).
2. **Ordered checklist** — the Phase 2 entries, in Phase 1's sequence, as literal checkboxes
   (`- [ ] ...`) so progress through the plan is trackable across sessions.
3. **Explicit stop points** — after every `new real infra` item and before any tier transition
   (`dev` → `stg`, `stg` → `prod`), mark the checklist with a note to get explicit user
   confirmation before continuing.

This file is **committed, not gitignored**.

## Handoff

This skill does not execute anything, and never applies Terraform locally — this project's
standing rule is PR/CI only, never a local `apply`. Actually executing the plan is
**`6.4-deploy-organization`**'s job: it picks the next actionable line, makes the real edit (a
pattern-specific tfvars entry, a brand-new-unit scaffold, a cross-unit grant, or an
independent-path `05.x` edit), submits it via `4.5-open-terraform-pr`, and checks the plan off with
the resulting PR link — one reviewable PR per unit of change, never a direct apply. Nothing about
`6.3`, `6.4`, or `4.5` shortcuts that discipline — this plan tells you *what* and *in what order*,
`6.4`/`4.5` are how each line reaches review, and the CI pipeline still decides *when it actually
applies*.

## Constraints

- Never lists an item the mapping doesn't call for, and never omits one it does.
- Never proposes building `stg`/`prod` for a BU before that BU's lower tier is checked off in the
  same plan (or already deployed, per the "Before starting" state check).
- Never treats this plan as authorization to run a local `terraform apply` for anything — every
  real item goes through `4.5-open-terraform-pr` and a human-reviewed PR, this document only
  sequences *when* that conversation happens for each item.
- Never re-plans an already-deployed resource — always diff against the real
  `*.auto.tfvars` state first.
- Never hardcodes a specific pattern's mechanism names (`pattern01_units.auto.tfvars`,
  `add-pattern01-unit.sh`, ...) as if they applied to every org — always read them from the org's
  own chosen pattern's `pattern-definition.md`.
