---
name: 6.2.1-build-pattern-module
description: Define and scaffold a brand-new organization pattern -- its docs/organization/<NN>-pattern/pattern-definition.md, its reusable Terraform module(s) under infrastructure/modules/organization/<NN>-pattern/, and (if it needs per-unit dedicated workspaces) its provider-scaffold script and root variables -- then validate via terraform validate/plan with a throwaway unit and register it in docs/organization/patterns.md. Never applies Terraform. Use when 6.2-map-databricks-pattern determines an org's needs don't fit any pattern already listed in patterns.md.
---

# Build pattern module (databricks repo)

Nested sub-skill of `6.2-map-databricks-pattern` — see [../SKILL.md](../SKILL.md) and
[../../README.md](../../README.md). Invoked only when Phase 1 of `6.2` determines no existing
pattern fits the org being mapped. Produces a new, reusable pattern — not tied to any one org —
that `6.2` (this org, and any future one with a similar shape) can then map onto.

**Scope**: this skill defines and builds the pattern's *mechanism* (docs + Terraform module +
scaffolding). It never creates a specific organization unit's data, never edits any org's
`org-structure.yaml`/mapping doc, and never applies Terraform.

## Naming: folder vs. identifier

Every pattern has **two spellings** of its name (see `docs/organization/patterns.md`'s own
naming-convention note) — never conflate them:

- **Folder name**: zero-padded, hyphenated ordinal — `01-pattern`, `02-pattern`, ... Used for
  `docs/organization/<NN>-pattern/` and `infrastructure/modules/organization/<NN>-pattern/`.
- **Terraform identifier stem**: the same ordinal without the hyphen — `pattern01`, `pattern02`,
  ... Used everywhere an actual HCL identifier or a filename tied to one is needed (Terraform
  identifiers can't start with a digit or contain a hyphen): `var.pattern<NN>_units`,
  `module "pattern<NN>_unit_<unit_key>"`, `infrastructure/pattern<NN>_units_<unit_key>.tf`,
  `infrastructure/scripts/add-pattern<NN>-unit.sh`.

Below, `<NN>-pattern` and `pattern<NN>` both refer to the *same* new pattern this skill is
building — pick the concrete number once (Phase 2) and use it consistently in both spellings.

## Before starting

- Confirm `6.2` actually determined no existing pattern fits — re-check `docs/organization/
  patterns.md` yourself rather than trusting that claim blindly; a pattern already covers the
  need more often than it first appears (e.g. a "shared workspace" requirement might just mean
  the org's units don't need `01-pattern`'s per-unit compute isolation, not that nothing existing
  applies — but there's currently only `01-pattern`, so today that check is usually quick).
- Read every existing pattern's `pattern-definition.md` and Terraform module — a new pattern
  should reuse the same primitive modules (`modules/workspace`, `modules/catalog`, `modules/group`,
  `modules/volume`) and the same conventions (naming, committed tfvars, PR-only apply) wherever
  they fit, not invent parallel idioms for things an existing primitive already does.

## Phase 1: Gather the new pattern's shape

Ask (don't assume) about each of these, grounded in what the org actually needs, not in abstract
design preference:

1. **Workspace strategy.** Does each unit need its own *dedicated* workspace (real compute/network
   isolation), or can units share a workspace with isolation done entirely via
   catalogs/schemas/groups (like this project's original independent path)? Only the former needs
   the per-unit-provider mechanism below — the latter is much simpler (a plain `for_each`,
   no scaffold script, similar to the independent path but with the new pattern's own catalog/
   naming shape).
2. **Catalog/schema granularity.** Is a line of business a catalog (like `01-pattern`), a schema
   within a shared catalog, or something else? What's the schema/medallion layout inside each
   catalog?
3. **Group/grant shape.** Same reader/writer/owner triad as `01-pattern`, or a different role
   vocabulary? Any cross-unit access needs (see Phase 3's provider-design note for how
   `01-pattern` handles this)?
4. **Anything beyond workspace/catalog/group/grant** — volumes, a genuinely new Databricks
   primitive not yet used by any pattern. Flag plainly if the org needs something this project's
   Terraform (any pattern) doesn't support yet (e.g. ABAC/masking) rather than inventing resources
   for it.

## Phase 2: Assign the pattern number and write its definition

- Next `NN` = one past the highest number already in `patterns.md`'s table (e.g. `02` if only
  `01-pattern` exists).
- Write `databricks/docs/organization/<NN>-pattern/pattern-definition.md`, following
  `01-pattern/pattern-definition.md`'s structure (Shape / Where it's implemented / Known
  limitations / Status / First instance) — every section, not an abbreviated version.

## Phase 3: Build the Terraform module

- Create `infrastructure/modules/organization/<NN>-pattern/` with the usual
  `versions.tf`/`variables.tf`/`main.tf`/`outputs.tf` (flat inside that one directory — no further
  nested subfolder, matching `01-pattern`'s layout). Compose existing primitive modules via
  relative `source` paths (two levels up from `modules/organization/<NN>-pattern/` reaches
  `infrastructure/modules/` itself, e.g. `../../workspace` — see
  `modules/organization/01-pattern/main.tf` for the working example) wherever Phase 1's answers
  call for them — don't reimplement `databricks_catalog`/`databricks_mws_workspaces`/etc. resource
  logic that an existing primitive module already covers correctly.
- If Phase 1 established the new pattern needs **per-unit dedicated workspaces**, this module
  needs its own catalog-scoped `databricks` provider per unit. Two ways to wire that (pick one,
  deliberately, don't default without considering the trade-off):
  - **Self-contained (`01-pattern`'s current design, prefer this unless cross-unit grants matter
    more)**: the module declares its own `provider "databricks" { alias = "this_unit", host =
    var.workspace.host, ... }` internally (see `modules/organization/01-pattern/providers.tf`) —
    verified empirically (`terraform validate`/`plan`) that this is legal as long as the caller
    never uses `count`/`for_each` on the module block (each unit gets its own distinctly-named
    block, never a loop). No separate root-level provider file at all — only
    `infrastructure/pattern<NN>_units_<unit_key>.tf` (the module call) is needed per unit, via
    `infrastructure/scripts/add-pattern<NN>-unit.sh` (mirrors `add-pattern01-unit.sh`, renamed
    throughout: `module "pattern<NN>_unit_<unit_key>"`, `var.pattern<NN>_units`). Cross-unit access
    (a different unit's group reading this unit's catalog) then has to be an input on *this*
    unit's own module call — mirror `01-pattern`'s `extra_grants` (a list of `{catalog_key,
    group_name, privileges}`, merged into the same `databricks_grants` resource as the catalog's
    own reader/writer/owner triad — Databricks only allows one grants resource per securable, so
    it can't be a second, separate resource).
  - **Root-declared** (the alternative, if this pattern's cross-unit-grant ergonomics matter more
    than saving one root file per unit): a `provider "databricks" { alias = "<unit_key>" ... }`
    block in `infrastructure/pattern<NN>_providers.tf`, passed into the module via `providers =
    { databricks = databricks.<unit_key> }`. This keeps each unit's provider nameable from the
    root, so a cross-unit grant can be a standalone resource in
    `infrastructure/pattern<NN>_cross_grants.tf` naming that provider directly — simpler
    cross-grants, one more root file per unit.
- If Phase 1 established units can **share a workspace**: no per-unit provider mechanism needed at
  all — a single `infrastructure/pattern<NN>.tf` with a normal `for_each`-based module/resource
  block (same idiom as the independent path's `catalogs.tf`) is sufficient; skip the scaffold
  script entirely, since there's no per-instance Terraform limitation to work around in this case.
- Add root `variables.tf` entries (`var.pattern<NN>_units`, and — only for the root-declared
  provider option above — a `var.pattern<NN>_unit_auth` map for host/profile), including
  naming-convention `validation` blocks mirroring `01-pattern`'s (prod-only enforcement, same regex
  family) adapted to this pattern's actual catalog key shape.

## Phase 4: Validate (never apply)

- `terraform validate` on the full config.
- Scaffold (if applicable) and populate a **throwaway unit** — a fake `unit_key` with placeholder
  data — and run `terraform plan -target=module.pattern<NN>_unit_<throwaway_key>` (or the
  equivalent resource address for a shared-workspace pattern). Confirm a clean plan (some N
  resources to add, 0 errors) before trusting the module.
- **Remove every throwaway artifact** before finishing — the generated per-unit file, any
  root-declared provider-alias block (if that design was chosen), any temporary `*.auto.tfvars` —
  same discipline `01-pattern` was built and tested with. If the pattern has a cross-unit-access
  notion, test it too (two throwaway units, one referencing the other's group output), not just a
  single unit in isolation. Re-run `terraform validate` after cleanup to confirm nothing was left
  dangling.
- Run a full, untargeted `terraform plan` and confirm it fails (if it fails at all) only at
  whatever pre-existing point it already failed at before this pattern was added — a new pattern
  must introduce zero regressions to the independent path or any other existing pattern.

## Phase 5: Register

- Add a new row to `docs/organization/patterns.md`'s table: pattern name (`<NN>-pattern`, linked
  to its `pattern-definition.md`), one-line strategy, Terraform module path, scaffold script (or
  "none — shared workspace" if Phase 3 skipped it), status (`Built + validated, not applied`).

## Constraints

- Never defines a new pattern when `6.2` should have reused an existing one — re-verify against
  `patterns.md` yourself before starting Phase 1.
- Never applies Terraform, locally or otherwise, at any point — this skill only ever validates and
  plans (with throwaway data, always cleaned up), never `apply`.
- Never reimplements resource logic an existing primitive module (`modules/workspace`,
  `modules/catalog`, `modules/group`, `modules/volume`) already provides — compose them.
- Never conflates the folder spelling (`<NN>-pattern`) with the identifier spelling
  (`pattern<NN>`) — Terraform identifiers can't start with a digit or contain a hyphen, so using
  the folder spelling in a variable/module name fails outright.
- Never leaves throwaway validation artifacts (a fake unit's scaffolded file, provider block, or
  `*.auto.tfvars` entries) in the repo once Phase 4 is done.
- Never skips Phase 5 — an unregistered pattern is invisible to every future `6.2` run, which risks
  a duplicate pattern being built for the same need later.
- Never invents Databricks capability this project doesn't have anywhere yet (row/column masking,
  service-principal groups, multi-cloud) just because a new pattern was asked for — say so plainly
  instead, same as every other skill in this group.
