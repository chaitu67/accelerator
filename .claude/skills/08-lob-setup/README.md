# 08-lob-setup skills

Skills in this group add **one new line of business, as a Unity Catalog catalog, to a business
unit that already has a real, `RUNNING` workspace** — deployed either via `07-business-unit-setup`
(a unit added after the org's initial rollout) or as part of `06-organization-setup`'s original
`6.4-deploy-organization` run. This is the "catalogs follow-up" half of the two-phase reality both
of those already establish, scoped to one new catalog at a time rather than a unit's whole initial
set.

Numbered `08` (after `07`) because it assumes a real workspace with a known host already exists —
this group never creates a workspace itself; that's `07-business-unit-setup`'s (or `06`'s, or
`09-environment-setup`'s) job. A catalog always belongs to one specific (business unit ×
environment tier) unit — its own `unit_key` (`<bu_key>_<env>`), its own
`pattern<NN>_units.auto.tfvars` entry (confirmed against `meridian-financial`'s mapping: e.g.
`retail-dev`'s catalogs are a separate set from `retail-prod`'s). A LOB needed across more than one
of a BU's tiers means running this group once per tier, never once for the whole BU.

## Covers the flat-unit case too

A business unit with no line-of-business split still needs exactly one catalog — domain-only, no
subdomain (per each pattern's own `pattern-definition.md`, e.g. `01-pattern`'s "a unit with no LOB
split gets one catalog per environment tier"). Run this group once for such a unit, with no LOB
name given, to create that one flat catalog — the same mechanism as a genuine LOB, just without a
`lines_of_business` entry in `org-structure.yaml`.

## Pipeline

```
8.1-discover-line-of-business  -> org-structure.yaml (lines_of_business entry, if a genuine LOB)
                                   + databricks-mapping.md updated with the new catalog
8.2-deploy-line-of-business    -> the unit's existing pattern<NN>_units.auto.tfvars entry updated
                                   (workspace.host set to the real URL if still null, catalogs map
                                   gets the new entry), submitted via 4.5-open-terraform-pr
```

## Skills in this group

- `8.1-discover-line-of-business` — interviews the user, one `AskUserQuestion` pop-up at a time,
  for a single new LOB/catalog under an existing, already-`RUNNING` business unit: slug, display
  name, environment tier(s) (a subset of that unit's own, not the org-wide set), schemas, and
  reader/writer/owner membership. Requires the target unit to already exist in
  `org-structure.yaml`/`databricks-mapping.md` and its workspace to be confirmed `RUNNING`.
- `8.2-deploy-line-of-business` — takes the catalog `8.1` just added and actually creates it:
  updates the unit's existing `pattern<NN>_units.auto.tfvars` entry (setting `workspace.host` to
  the real URL if it's still `null`, and adding the new catalog to its `catalogs` map), then
  submits via `4.5-open-terraform-pr`. Never re-scaffolds the unit itself, never applies Terraform
  locally.

## Before running anything in this group

Confirm the target (business unit × environment tier) already exists in
`org-structure.yaml`/`databricks-mapping.md` and that its own workspace is actually `RUNNING` (ask
the user, or check `terraform output workspace_urls` / the Account Console) — a LOB catalog's
provider needs a real host to attach to. If the unit itself doesn't exist yet, or this particular
tier's workspace hasn't been created, point at `07-business-unit-setup` (a unit's first tier),
`09-environment-setup` (a unit's later tier), or `6.4-deploy-organization` (a unit that predates
either group) instead of improvising.

## Convention

- Each skill here still needs its own `SKILL.md` per the usual skill format — this README is an
  index for the group, not a skill itself.
- Keep examples generic, never a real company's name or org chart — same rule as
  `06-organization-setup`/`07-business-unit-setup`, since `databricks` is public.

## Constraints (apply to the whole group)

- Never creates a business unit's workspace — that's `07-business-unit-setup`'s (or `06`'s, or
  `09-environment-setup`'s) job; this group only ever adds a catalog to a (unit × tier) whose
  workspace already exists and is `RUNNING`.
- Never covers more than one environment tier in a single `8.1`/`8.2` run — a LOB needed across
  several of a BU's tiers means running this group again per tier.
- Never proceeds against a unit whose workspace isn't confirmed `RUNNING` — surfacing that gap is
  `8.1`'s job, not something to skip past.
- Never applies Terraform locally, in any skill in this group — `8.2` submits via
  `4.5-open-terraform-pr` only.
- Never re-scaffolds or hand-edits `pattern<NN>_units_<unit_key>.tf` — a new catalog is a pure
  `pattern<NN>_units.auto.tfvars` edit, no code-generation step needed (unlike a brand-new unit).
