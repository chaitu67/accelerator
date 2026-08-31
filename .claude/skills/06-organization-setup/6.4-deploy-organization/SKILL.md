---
name: 6.4-deploy-organization
description: Take the next actionable line(s) from an org's deployment-plan.md (from 6.3-generate-deployment-plan, under docs/organization/<NN>-pattern/<org-slug>/), make the actual code/tfvars change for it using that pattern's own mechanism (a pattern<NN>_units.auto.tfvars entry, a brand-new unit's scaffold, a cross-unit grant, or an independent-path 05.x edit), then submit it via 4.5-open-terraform-pr and check off the plan. Never applies Terraform locally. Use when the user wants to actually start executing a 06-organization-setup deployment plan, one reviewable PR at a time.
---

# Deploy organization (databricks repo)

Fourth skill in the `06-organization-setup` group — see [../README.md](../README.md). Consumes
`6.3-generate-deployment-plan`'s output; hands off to `4.5-open-terraform-pr`
(`04-github-cicd` group) for the actual commit/push/PR mechanics, and to the relevant `05.N-*`
skill for anything on the independent path.

**Scope**: this skill makes one unit of real change (see "What counts as one unit" below) and
gets it into a PR, using whichever pattern the org's mapping doc says applies. It never runs
`terraform apply` — locally or otherwise — and never merges a PR. Matches this project's standing
rule: Terraform is applied only via PR/CI, never a local `apply`.

## Before starting

- Require a `deployment-plan.md` to exist under some `docs/organization/<NN>-pattern/<org-slug>/`
  folder (from `6.3-generate-deployment-plan`). If it doesn't, stop and point at `6.3` rather than
  inventing a plan here.
- Read that org's `pattern-definition.md` one level up
  (`docs/organization/<NN>-pattern/pattern-definition.md` — pattern-level, not per-org) for the
  exact mechanism names this plan's lines refer to — its Terraform module, its scaffold script
  (`add-pattern<NN>-unit.sh`), its unit-data variable (`pattern<NN>_units.auto.tfvars`), and how it
  handles cross-unit grants (`01-pattern` uses an `extra_grants` input on the target unit's own
  module call; a pattern that declared its provider at the root instead would use a standalone
  `pattern<NN>_cross_grants.tf`). Don't assume `01-pattern`'s specific names or mechanism apply to a
  different org's plan without checking which pattern it actually uses.
- Confirm `4.1-check-cicd-prerequisites` passes (or already confirmed) — `4.5-open-terraform-pr`
  assumes the pipeline it submits into already exists.
- Re-read the plan's current checkbox state — don't assume it matches what's actually committed;
  a previous `6.4` run (this session or an earlier one) may have already submitted some lines in
  a PR still awaiting review/merge. Cross-check against real repo state (open PRs via
  `gh pr list`, and the current `*.auto.tfvars`/`pattern<NN>_units_*.tf` files) before picking the
  next line, not just the plan doc's checkboxes.

## What counts as "one unit" of change

Submit **one organization unit's workspace-and-catalogs at a time** (or the equivalent whole-unit
grouping for a pattern whose shape differs), not one LOB catalog at a time — a pattern like
`01-pattern` already takes an entire unit's workspace + all its LOB catalogs in one
`pattern<NN>_units.auto.tfvars` entry, so that's the natural PR granularity (the
`deployment-plan.md` checklist nests LOB catalog lines under their unit's workspace line for
exactly this reason). A cross-unit grant line and an independent-path line are each their own
unit of change.

## The two-phase reality for a brand-new unit — read before Phase 2

*Applies to any pattern whose units need their own dedicated workspace (check its
`pattern-definition.md`; `01-pattern` does).* A unit's LOB catalogs use a `databricks` provider
scoped to *that unit's own workspace* (for `01-pattern`, self-contained inside the module,
parameterized by `workspace.host` in its own `pattern<NN>_units.auto.tfvars` entry), which needs a
real `host` — only knowable once the workspace has actually been created and reports `RUNNING`.
So a brand-new `unit_key`'s *first* PR can only ever contain the workspace (via a `host = null`,
`catalogs = {}` entry); its LOB catalogs are a **second, follow-up PR** once the first has merged,
applied, and the real workspace URL is known. Don't bundle "create the workspace" and "populate
its catalogs" into one PR for a unit that has never been applied before — say so and split them,
even if the deployment plan's checklist nests them as if they were one line. (A pattern whose
units *share* a workspace instead has no such split — check its `pattern-definition.md` before
assuming this applies.)

## Phase 1: Pick the next line

From `deployment-plan.md`, in order, find the next line that is:

- Not already checked off.
- Not blocked by an unresolved open question noted on that line (surface it to the user instead
  of guessing an answer).
- Not waiting on a dependency that hasn't merged yet (a cross-unit grant waiting on either unit's
  catalogs; a unit's catalogs-only follow-up waiting on its own workspace-only PR having merged
  and applied).

Confirm with the user which line to submit next if more than one is unblocked — don't silently
pick one, since PR ordering/pacing is their call, especially around `prod` tiers.

## Phase 2: Make the change

Using the org's actual pattern's mechanism names (from its `pattern-definition.md`):

- **Brand-new unit, workspace-only (first PR for this `unit_key`)**: run
  `add-pattern<NN>-unit.sh <unit_key>` (idempotent — confirm it actually scaffolded something, not
  "Nothing to do" for a unit you expected to be new). Add its `pattern<NN>_units.auto.tfvars` entry
  with `workspace = {...}` populated from the mapping doc, `workspace.host` left `null` (nothing
  references it yet, since `catalogs` is empty — don't fabricate a placeholder URL), and
  `catalogs = {}`.
- **Existing unit, catalogs follow-up**: confirm the workspace is actually `RUNNING` first (ask
  the user, or check `terraform output workspace_urls` / the Account Console) and get its real
  URL. Update this same `pattern<NN>_units.auto.tfvars` entry: set `workspace.host` to that real URL,
  and populate `catalogs` with the LOB catalog(s) from the mapping doc (bucket names, schemas,
  role emails).
- **Cross-unit grant** (for a pattern like `01-pattern` with a self-contained per-unit provider):
  hand-edit the *target* unit's own `pattern<NN>_units_<unit_key>.tf` to add an `extra_grants` entry
  (per its own header-comment template) — this is the one part of a scaffolded file meant to be
  edited by hand, not regenerated. (For a pattern that declared its provider at the root instead,
  this would be a standalone resource in `pattern<NN>_cross_grants.tf` — check the pattern's own
  `pattern-definition.md` for which applies.)
- **Independent-path line**: run the named `05.N-*` skill's own Phase 1 (gather) and Phase 2
  (implement/scaffold) — stop before its Phase 3, since submission happens in Phase 3 below
  instead of that skill's own local-apply option.

Never hand-edit `pattern<NN>_units_<unit_key>.tf` for anything other than its `extra_grants` entries
(if the pattern uses that mechanism) — every other argument in that file only ever comes from
that pattern's `add-pattern<NN>-unit.sh` scaffold, and every real value comes from
`pattern<NN>_units.auto.tfvars`.

## Phase 3: Submit

Invoke `4.5-open-terraform-pr` with:

- **Branch name**: describes the specific line, e.g. `infra/01-pattern-unit-retail-dev`,
  `infra/01-pattern-unit-retail-dev-catalogs`, `infra/01-pattern-cross-grant-risk-compliance-retail`.
- **Commit message / PR title**: what this line actually does (e.g. "Create retail_dev 01-pattern
  unit workspace" or "Add brokerage/advisory catalogs to retail_dev"), not a generic placeholder.
- **PR body**: reference the plan line(s) from `deployment-plan.md` this covers, and call out
  explicitly if this is a workspace-only first phase awaiting a catalogs follow-up.

Get the PR URL back from `4.5` before continuing.

## Phase 4: Update the plan

Edit `deployment-plan.md`: check off `- [ ]` → `- [x]` for the line(s) just submitted, and append
the PR URL next to it. If this was a brand-new unit's workspace-only phase, **don't** check off
its nested LOB catalog lines yet — add a note that they're waiting on this PR merging/applying and
the real workspace URL. This file is **committed, not gitignored** — its own update can ride in
the same PR `4.5` just opened, or a small follow-up commit to the same branch before it's
reviewed; don't leave the plan doc silently out of sync with what was actually submitted.

## Constraints

- Never runs `terraform apply` (local or otherwise) — submission is a PR, review/merge/apply are
  human decisions and CI, respectively.
- Never bundles a brand-new unit's workspace creation and its catalogs into one PR, for any
  pattern whose units need dedicated workspaces — see "The two-phase reality" above.
- Never fabricates a workspace host/URL — get it from `terraform output` or the user, or leave it
  `null` when genuinely not yet knowable (workspace-only phase).
- Never picks the next plan line without checking real repo/PR state first — a line can look
  unchecked in `deployment-plan.md` while already sitting in an open, unmerged PR from a prior
  `6.4` run.
- Never hand-edits `pattern<NN>_units_<unit_key>.tf` beyond its `extra_grants` entries (if the
  pattern uses that mechanism) — every other argument only ever comes from that pattern's own
  `add-pattern<NN>-unit.sh` scaffold.
- Never assumes `01-pattern`'s specific file/variable names apply to a different org without
  checking that org's own `pattern-definition.md` first.
- Never checks off a plan line before `4.5-open-terraform-pr` has actually returned a PR URL for
  it.
