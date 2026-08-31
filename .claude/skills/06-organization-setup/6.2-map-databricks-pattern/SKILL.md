---
name: 6.2-map-databricks-pattern
description: Map a discovered org model (org-structure.yaml, from 6.1-discover-org-structure) onto concrete Databricks primitives, using an existing pattern from docs/organization/patterns.md if one fits, or defining a new one (via 6.2.1-build-pattern-module) if none does. Writes databricks-mapping.md under that pattern's docs/organization/<pattern>/<org-slug>/ folder. Use when the user has an org model and wants to know how it should become workspaces, catalogs, schemas, and groups.
---

# Map organization to Databricks pattern (databricks repo)

Second skill in the `06-organization-setup` group — see [../README.md](../README.md). Consumes
`6.1-discover-org-structure`'s output; feeds `6.3-generate-deployment-plan`.

**Scope**: this skill decides *which pattern applies* (reusing an existing one, or defining a new
one via `6.2.1`) and, given that pattern, *shape* (which workspace(s), which catalogs/schemas,
which groups/grants) — then writes it down. It does not decide the literal rollout order or make
any real edit — that's `6.3`/`6.4`. It does not run Terraform.

## Before starting

- Require an `org-structure.yaml` to exist (from `6.1-discover-org-structure`, default location
  `databricks/docs/organization/01-pattern/<org-slug>/org-structure.yaml`). If it doesn't, stop and point at
  `6.1` rather than inventing an org model here.
- Read `databricks/docs/organization/patterns.md` in full — the registry of every pattern defined
  so far, what each one's strategy is, and which Terraform module/scaffold script realizes it.
- Read `docs/naming-conventions.md` in full (or confirm already in context) — every name this
  skill proposes must satisfy it, not approximate it.
- Read `05-databricks-terraform-deployment`'s README and each `5.N-*/SKILL.md` (or confirm already
  in context) — any mapping must reflect what those modules can *actually* do today.

## Phase 1: Pick or define the pattern

Compare the org model's stated needs (workspace/compute isolation requirements, catalog/LOB
granularity, cross-unit access, any sensitivity/isolation flags from `org-structure.yaml`) against
every pattern listed in `patterns.md`:

- **An existing pattern fits** when its shape (see that pattern's own `pattern-definition.md`)
  genuinely matches what this org needs — don't force-fit an org onto `01-pattern`'s "workspace per
  unit × env, LOB = catalog" shape just because it's the only one that exists today, if the org
  actually needs something structurally different (e.g. a single shared workspace with
  catalog-only isolation, or units that don't need per-unit compute isolation at all). Reusing a
  pattern that doesn't actually fit produces the wrong infrastructure shape just as surely as
  inventing one from scratch would.
- **No existing pattern fits** → invoke **`6.2.1-build-pattern-module`** to define and scaffold
  the next one (whatever `patterns.md`'s table doesn't already have a row for) before continuing.
  Don't map the org onto a not-yet-built pattern — `6.2.1` must actually finish (module built,
  validated via `terraform validate`/a throwaway-unit `plan`, registered in `patterns.md`) before
  Phase 2 proceeds.
- **If the org model itself is ambiguous about which shape it needs** (e.g. no sensitivity/
  isolation flags either way), default to the org's simplest fit among *existing* patterns rather
  than defining a new one speculatively — ask the user to confirm rather than guessing toward the
  more complex option.

Record which pattern applies (e.g. `01-pattern`) — everything below and in `6.3`/`6.4` is scoped to
it. If `org-structure.yaml` currently lives under a different pattern's folder than the one just
chosen (e.g. it was written to the default `01-pattern/` by `6.1` before this decision was made),
move it (and any of its own already-written docs) into the correct `docs/organization/<pattern>/<org-slug>/`
folder now.

## Phase 2: Instantiate the pattern's shape

Apply the chosen pattern's own `pattern-definition.md` mechanically against this org's
`org-structure.yaml` — don't re-derive the pattern's rules from scratch here, and don't bend them
to this org's specifics beyond what the pattern already parameterizes (a genuine mismatch means
Phase 1 picked the wrong pattern, not that this pattern needs a one-off exception).

For `01-pattern` specifically (today's only defined pattern), that means, for every business unit
and shared department in `org-structure.yaml`, and every environment tier listed under it:

- **One dedicated workspace per (unit × environment tier)**, named `<unit_key>-<env>` for display
  purposes (e.g. `retail-dev`) — the Terraform `unit_key` itself must be underscore-only, no
  hyphens (a Terraform identifier rule — see `01-pattern/pattern-definition.md`). Its `aws_region`
  comes from `org-structure.yaml`'s `environment_regions[<env>]` (or that unit's own
  `region_overrides[<env>]`, if it stated one) — never left unset or guessed. If
  `org-structure.yaml` scoped the org to a single region, every workspace just uses that one
  region and `environment_regions` won't exist at all; don't treat its absence as a gap in that
  case.
- **One catalog per (unit × LOB × environment tier)**, living inside that unit's workspace.
  Catalog `domain` = the unit's `key`; `subdomain` = the LOB's `key` (naming-conventions.md). A
  unit with no LOB split gets one catalog per environment tier (domain only).
- **If `org-structure.yaml` has a `dr` block**: every unit that has a tier listed in `dr.tiers`
  also gets one additional, workspace-only DR standby — named `<unit_key>-<tier>-dr` (e.g.
  `retail-prod-dr`), `aws_region` = `dr.region`, `catalogs = {}` permanently (not the ordinary
  two-phase "catalogs follow later" case — this workspace never gets catalogs through this
  pipeline at all; data replication into it is a separate concern). Applies to every unit with
  that tier — both business units and shared departments — unless the user narrowed the scope
  when asked; don't narrow it yourself.
- **Schemas**: `bronze`/`silver`/`gold` per catalog by default, unless `org-structure.yaml`'s
  `sensitivity_notes` imply a different data-layering need (ask, don't assume).
- **Groups per role**: the standard `reader`/`writer`/`owner` triad per catalog
  (`acl_<catalog_key>_<role>`). A shared department needing access *across* multiple units'
  catalogs gets **one group**, with multiple cross-unit grants (each an `extra_grants` entry on
  the *target* unit's own module call — see `01-pattern/pattern-definition.md`), not a duplicated
  group per unit.
- **PII / sensitivity flags** carried over from `org-structure.yaml` — flag any stated hard
  PII-masking requirement as **not yet buildable** (row/column `abac` masking is reserved
  vocabulary, not implemented anywhere in this project) rather than silently downgrading it to an
  ordinary `reader` grant that doesn't actually enforce it.

A different pattern's own `pattern-definition.md` will spell out its own equivalent rules — follow
those instead when a different pattern was chosen in Phase 1.

Compute and say out loud the real infra count this implies (for `01-pattern`: total workspaces, one
per unit × environment tier — a modest 4-BU org can easily mean 15-20 real workspaces) before the
mapping doc goes further. Never silently shrink the pattern's shape because the count looks
large — say the real count and cost implication out loud and let the user decide to scope down.

## Phase 3: Write the mapping

Write (or update) `databricks/docs/organization/<pattern>/<org-slug>/databricks-mapping.md` (e.g.
`01-pattern/northwind-financial/databricks-mapping.md`), structured as:

1. **Pattern used** — which one (link to its `pattern-definition.md`), and why it fits this org
   (or why a new one had to be defined).
2. **Per-unit table** — columns: org unit, workspace name, catalog name(s) per environment,
   schemas, groups (with role), grants, open gaps (e.g. "PII masking requested, not yet
   buildable").
3. **Constraints carried forward** — anything from the pattern's own known limitations, or `05`'s,
   that materially affects this org (e.g. `01-pattern`'s two-phase workspace-then-catalogs
   requirement for any brand-new unit, or "`5.3`/`01-pattern` doesn't grant workspace login access
   itself").

This file is **committed, not gitignored**.

## Constraints

- Never maps an org onto a pattern that doesn't genuinely fit its stated needs, just because it's
  the only (or the simplest) one that already exists — invoke `6.2.1` instead when none does.
- Never invents a new pattern when an existing one already fits — check `patterns.md` first, every
  time, even when the org model looks superficially different from previous ones.
- Never writes the mapping doc without stating, for each *brand-new* unit under `01-pattern` (or
  whatever pattern applies), that it needs that pattern's one-time scaffold script run before its
  data becomes a pure tfvars edit — that step is load-bearing, not a footnote.
- Never silently shrinks a pattern's shape because the resulting infra count looks large — say the
  real count and cost implication out loud and let the user decide to scope down.
- Never invents a naming pattern that deviates from `docs/naming-conventions.md` — if the org
  model implies a name shape the convention doesn't support (e.g. a fourth environment tier, a
  unit key with uppercase or hyphens), surface the conflict and ask the user to resolve it rather
  than quietly bending either one.
- Never claims a security/isolation capability this project doesn't actually implement yet
  (row/column masking, service-principal groups) — say "not yet buildable" and point at
  naming-conventions.md's reserved-vocabulary note instead.
- Never writes to any `*.auto.tfvars` file or runs `add-<pattern>-unit.sh` — mapping is a planning
  document; `6.3` sequences it and `6.4` is what eventually makes real edits.
- Never leaves a workspace's region unassigned or guessed when `org-structure.yaml` names more
  than one region — every workspace needs one concrete `aws_region`, resolved from
  `environment_regions`/`region_overrides`. If `org-structure.yaml` predates this field (an org
  discovered before it existed) and has multiple regions with no mapping, stop and ask rather than
  picking one.
