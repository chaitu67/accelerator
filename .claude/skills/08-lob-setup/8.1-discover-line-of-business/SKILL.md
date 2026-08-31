---
name: 8.1-discover-line-of-business
description: Interview the user, one AskUserQuestion pop-up at a time, to add ONE new line-of-business catalog to a business unit that already exists in org-structure.yaml/databricks-mapping.md and already has a real, RUNNING workspace. Adds a lines_of_business entry to org-structure.yaml (or, for a flat unit's one domain-only catalog, none at all) and a catalog row to databricks-mapping.md. Does not edit any Terraform file. Use when the user wants to add a new line of business, or a flat unit's first catalog, to an existing business unit.
---

# Discover line of business (databricks repo)

First skill in the `08-lob-setup` group — see [../README.md](../README.md). Produces the catalog
entry that `8.2-deploy-line-of-business` then actually creates.

**Scope**: adds one catalog's worth of planning to a business unit that's *already established and
already has a real workspace*. Never creates the business unit itself (that's
`07-business-unit-setup`, or `06-organization-setup` for a unit from the org's original rollout)
and never decides pattern/catalog shape from scratch — inherited as-is from that org's existing
`databricks-mapping.md`/`pattern-definition.md`. Never touches Terraform.

## Before starting

- Require `org-structure.yaml` and `databricks-mapping.md` to already exist for the target org, and
  the target business unit to already appear in both (from `6.1`/`6.2`, or `7.1`). If the unit
  itself doesn't exist yet, stop and point at `07-business-unit-setup` instead of inventing it
  here.
- **Pick which single (business unit × environment tier) this catalog goes into**, and **confirm
  that tier's workspace is actually `RUNNING`** — ask the user, or check `terraform output
  workspace_urls` / the Account Console. A LOB catalog belongs to exactly one tier's own workspace
  (`unit_key` = `<bu_key>_<env>`, its own `pattern<NN>_units.auto.tfvars` entry — see
  `7.1-discover-business-unit`'s "Terraform unit granularity" note); a LOB needed across more than
  one of this unit's tiers means running `8.1`/`8.2` again per tier, never one run covering several.
  A LOB catalog needs a real host to attach its provider to; don't proceed against a tier whose
  workspace is still workspace-only (`host = null` in its `pattern<NN>_units.auto.tfvars` entry) or
  not yet merged/applied.
- Read the org's `pattern-definition.md` for catalog-shape rules (e.g. `01-pattern`: catalog
  `domain` = the unit's own key, `subdomain` = the LOB's key; `bronze`/`silver`/`gold` schemas by
  default).

## Phase 1: Gather

1. **Does this unit already split into lines of business, or is this its one flat catalog?** A unit
   that already has `lines_of_business` entries in `org-structure.yaml` is just getting another
   one; a unit with none yet either stays flat (one domain-only catalog, asked for here once — no
   `lines_of_business` entry gets written) or starts splitting now — the user's call, don't assume
   either direction.
2. **If a genuine LOB**: its slug + display name (underscore-only, starts with a letter — becomes
   the catalog `subdomain`, same rule as `docs/naming-conventions.md`'s `domain`).
3. **Confirm the single environment tier** this run targets (from "Before starting" — must be one
   of *this unit's own* `environments` in `org-structure.yaml`, not the org-wide
   `organization.environment_tiers`, and must already have a `RUNNING` workspace) — a unit that only
   ever asked for `dev`/`prod` can't get a `stg` catalog here, and a tier without a deployed
   workspace yet needs `09-environment-setup` first.
4. **Schemas**, if different from the `bronze`/`silver`/`gold` default.
5. **Reader/writer/owner membership** (email lists) for this catalog's group triad — the standard
   `acl_<catalog_key>_<role>` triad every pattern instance creates per catalog.
6. **Any data-sensitivity or PII notes** specific to this LOB/catalog — record verbatim, flag any
   masking ask as not-yet-buildable rather than promising it (same as `6.1`/`7.1`).

## Phase 2: Update org-structure.yaml

- **Genuine LOB**: append to that unit's `lines_of_business` list, following
  `6.1-discover-org-structure`'s Phase 2 schema.
- **Flat catalog**: no `lines_of_business` entry — its absence is exactly what "no LOB split"
  already means. Record Phase 1 item 6's sensitivity notes on the unit itself if any were given.

## Phase 3: Update databricks-mapping.md

Add (or extend) this unit's row with the new catalog: name (per naming-conventions.md), schemas,
groups (with role), grants, open gaps — following `6.2-map-databricks-pattern`'s Phase 3 table
format.

## Constraints

- Never proceeds if the unit's workspace isn't confirmed `RUNNING` — surface that gap plainly
  rather than skipping past it.
- Never invents a LOB the user didn't state.
- Never creates a new business unit — if the named unit doesn't exist in `org-structure.yaml`,
  point at `07-business-unit-setup` instead.
- Never writes to any `*.auto.tfvars` file — this skill only edits
  `org-structure.yaml`/`databricks-mapping.md`; `8.2-deploy-line-of-business` makes the real edit.
- Never assigns this catalog an environment tier the unit itself doesn't have.
- Never claims a security/isolation capability this project doesn't implement yet (row/column
  masking) — say "not yet buildable," same as `6.1`/`6.2`.
