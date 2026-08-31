---
name: 6.0-manage-organization
description: Single entry point for any Databricks organization-setup request -- discovering/mapping/planning/deploying a whole new org (6.1-6.4), adding a new business unit or department (07-business-unit-setup), adding a new line of business/catalog (08-lob-setup), or promoting a unit to a new environment tier (09-environment-setup). Inspects current repo state (which docs/tfvars/scaffold files already exist) to work out which of those actually applies, then hands off to it, rather than requiring the user to already know which numbered skill covers their request. Use whenever the user wants to set up, grow, or modify a Databricks organization's structure and it isn't already obvious which specific skill applies.
---

# Manage organization (databricks repo) — entry point / router

Nested inside the `06-organization-setup` group — see [../README.md](../README.md) — but unlike
that README, this file **is** an invocable skill: the single front door for anything about setting
up or growing a Databricks organization's structure. `6.1`–`6.4`, and the three sibling groups this
area has grown since (`07-business-unit-setup`, `08-lob-setup`, `09-environment-setup`), are all
genuinely one capability from the user's point of view — "manage my organization's structure" —
even though each is its own independently-triggerable skill under the hood. This skill is what
makes that true: read the request, check real repo state, and route to the right specific skill
instead of the user needing to already know this project's own internal numbering.

**Scope**: this skill only decides *which other skill applies* and hands off to it. It never
discovers, maps, plans, or deploys anything itself — every one of those actions belongs to
whichever component skill Phase 1 below identifies.

## The whole family, in one map

```
6.1-discover-org-structure     -- brand-new org, from nothing            -> org-structure.yaml
6.2-map-databricks-pattern     -- decide/apply a pattern for that org    -> databricks-mapping.md
6.3-generate-deployment-plan   -- sequence the whole org's rollout       -> deployment-plan.md
6.4-deploy-organization        -- execute the next plan line, PR it     -> real infra, one PR at a time

07-business-unit-setup (7.1/7.2)  -- add ONE new BU/department to an org that already exists
                                     (workspace only, its first environment tier)
08-lob-setup (8.1/8.2)            -- add ONE new LOB/catalog to a (BU x tier) that's already RUNNING
09-environment-setup (9.1/9.2)    -- promote an existing BU to ONE new environment tier
                                     (workspace only, once its lower tier(s) are deployed)
```

`07`/`08`/`09` are the incremental, day-two siblings to `6.1`–`6.4`'s whole-org pipeline — each
group's own README explains why they're split out this way (mainly: re-discovering and re-mapping
an entire org every time the user just wants to add one BU, one catalog, or one tier would be
wasteful and risks re-litigating already-settled decisions).

## Phase 1: Figure out which skill actually applies

Don't ask the user "which skill do you want" — infer it from what they said plus real repo state,
the same way every component skill's own "Before starting" section already checks state before
proceeding. Check, in order:

1. **Does an org-slug even exist yet** for what the user's describing (a
   `docs/organization/<NN>-pattern/<org-slug>/` folder with `org-structure.yaml`)? If genuinely
   not (a brand-new org, or a company/structure never modeled here before) →
   **`6.1-discover-org-structure`**.
2. **Does `org-structure.yaml` exist but no `databricks-mapping.md`** for that org? →
   **`6.2-map-databricks-pattern`**.
3. **Does `databricks-mapping.md` exist but no `deployment-plan.md`**, and the user wants to move
   toward building the *whole* org as originally modeled? → **`6.3-generate-deployment-plan`**.
4. **Does `deployment-plan.md` exist with unchecked lines**, and the user wants to execute the next
   one? → **`6.4-deploy-organization`**.
5. **Is the org already fully discovered and mapped** (`org-structure.yaml` +
   `databricks-mapping.md` both exist), **and the user wants to add a business unit or department
   that doesn't exist yet** in `org-structure.yaml`? → **`07-business-unit-setup`**
   (`7.1-discover-business-unit` first).
6. **Does the named business unit already exist, and the user wants to add a line of
   business/catalog to it** (or give a flat unit its first catalog)? → **`08-lob-setup`**
   (`8.1-discover-line-of-business` first) — but only once that unit's target tier's workspace is
   confirmed `RUNNING`; if it isn't yet, that's actually case 5 or 7, not this one.
7. **Does the named business unit already exist and have at least one tier deployed, and the user
   wants to give it another environment tier** (e.g. a `dev`-only unit now wants `stg`/`prod`)? →
   **`09-environment-setup`** (`9.1-discover-environment` first).

If more than one reading is plausible (e.g. the org exists and so does the named BU, but it's
unclear whether the user means "add a new BU" vs. "add a LOB to the existing one"), ask a single
clarifying question rather than guessing — same discipline every component skill already applies
to its own ambiguous cases.

## Phase 2: Hand off, don't duplicate

Once the right skill is identified, invoke it directly — this router never re-implements any
component's own interview, mapping, planning, or deployment logic. Its entire job is Phase 1's
routing decision, plus carrying forward whatever the user already told it in this conversation so
the component skill doesn't have to re-ask.

## Constraints

- Never guesses which org/BU/tier the user means when more than one exists and the request is
  ambiguous — ask, same as every component skill's own discipline.
- Never re-implements `6.1`–`6.4`/`7.x`/`8.x`/`9.x`'s own logic here — this skill only routes.
- Never invents state that isn't real — the routing decision in Phase 1 is always based on actual
  files on disk (`org-structure.yaml`, `databricks-mapping.md`, `deployment-plan.md`, scaffolded
  `pattern<NN>_units_<unit_key>.tf` files, real Terraform/PR state), never assumed from the
  conversation alone.
- Never skips a component skill's own prerequisite checks just because this router already looked
  at some state — each one still verifies its own "Before starting" section independently; this
  router's job is only to pick the right door, not to vouch for what's behind it.
