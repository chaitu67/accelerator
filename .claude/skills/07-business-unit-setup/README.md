# 07-business-unit-setup skills

Skills in this group add **one new business unit (or shared department) to an org that already
exists** — its `org-structure.yaml`/`databricks-mapping.md` already committed, its pattern already
chosen (from `06-organization-setup`). Where `06`'s `6.1`–`6.4` discover and roll out an *entire*
org from nothing, this group is the narrower, incremental sibling for the far more common
day-two case: "the org is already modeled and mapped, now add one more unit to it."

Numbered `07` (after `06`, not nested inside it) because it assumes `06`'s output already exists —
this group never discovers an org from scratch and never decides which pattern applies; it reuses
whatever `6.2-map-databricks-pattern` already decided for this org.

## Scope: workspace only, not catalogs — and only the unit's first tier

This group creates the new unit's **workspace** and nothing else. Lines of business (catalogs)
for the new unit — even its one flat, no-LOB-split catalog, if it doesn't split — are deliberately
out of scope here; that's `08-lob-setup`'s job, run once the new workspace is actually `RUNNING`.
This mirrors `6.4-deploy-organization`'s own "two-phase reality" (a brand-new unit's workspace and
its catalogs can't land in the same PR/apply, since the catalog's provider needs the workspace's
real, Databricks-assigned URL) — just applied to one incrementally-added unit instead of a whole
org's rollout.

`7.2-deploy-business-unit` also only ever deploys the unit's **first (lowest) environment tier**.
Under `01-pattern` (and any pattern with dedicated per-unit workspaces), each (business unit ×
environment tier) is its own separate Terraform unit — its own `unit_key` (`<bu_key>_<env>`), own
workspace, own scaffolded file (confirmed against `meridian-financial/databricks-mapping.md`'s
`retail-dev`/`retail-stg`/`retail-prod`, three distinct workspaces for one BU). A unit that needs
more than one tier gets its later tiers from `09-environment-setup`, one at a time, `dev` before
`stg` before `prod` — never a second run of `7.2` for the same unit.

## Pipeline

```
7.1-discover-business-unit  -> org-structure.yaml + databricks-mapping.md updated with the new
                                unit (its full set of requested tiers; no lines_of_business yet)
7.2-deploy-business-unit    -> add-pattern<NN>-unit.sh scaffold + pattern<NN>_units.auto.tfvars
                                entry for the unit's FIRST tier only (unit_key <bu_key>_<env>,
                                host null, catalogs {}), submitted via 4.5-open-terraform-pr
                                        |
                                        +--> 08-lob-setup, once this tier's workspace is RUNNING
                                        |
                                        +--> 09-environment-setup, for this unit's next tier
```

## Skills in this group

- `7.1-discover-business-unit` — interviews the user, one `AskUserQuestion` pop-up at a time, for
  a single new business unit or shared department: slug, display name, environment tiers, region
  override, sensitivity notes, and (for a shared department) which existing BUs it needs access
  across. Requires the target org's `org-structure.yaml`/`databricks-mapping.md` to already exist.
  Writes the new unit into both files, following `6.1`/`6.2`'s own schemas exactly. Never asks
  about lines of business.
- `7.2-deploy-business-unit` — takes the unit `7.1` just added and actually creates its **first**
  tier's workspace: runs that org's pattern's `add-pattern<NN>-unit.sh <bu_key>_<env>` scaffold,
  adds the workspace-only `pattern<NN>_units.auto.tfvars` entry (`host = null`, `catalogs = {}`),
  and submits via `4.5-open-terraform-pr`. Never bundles catalogs into this PR, never deploys a
  second tier for the same unit (that's `09-environment-setup`), never applies Terraform locally.

## Before running anything in this group

Confirm `org-structure.yaml` and `databricks-mapping.md` already exist for the target org (from
`6.1-discover-org-structure`/`6.2-map-databricks-pattern`) and that its pattern is already decided.
If either is missing, this group doesn't apply yet — point at `06-organization-setup` instead of
improvising a pattern choice here.

## Convention

- Each skill here still needs its own `SKILL.md` per the usual skill format — this README is an
  index for the group, not a skill itself.
- Keep examples generic (abstract or already-established placeholder domains), never a real
  company's name or org chart — same rule as `06-organization-setup`, since `databricks` is public.

## Constraints (apply to the whole group)

- Never discovers or maps a whole org from scratch — that's `06-organization-setup`'s job; this
  group only ever adds one unit to an org that already has both files.
- Never decides or changes which pattern an org uses — inherited as-is from that org's existing
  `databricks-mapping.md`/`pattern-definition.md`. If the existing pattern genuinely doesn't fit
  the new unit's needs, stop and say so rather than forcing it — that's a `6.2` conversation.
- Never creates a line-of-business catalog for the new unit, even a flat, no-LOB-split one — that
  always goes through `08-lob-setup`, once the workspace is `RUNNING`.
- Never deploys more than one environment tier for a unit in a single `7.2` run — a unit needing
  `stg`/`prod` beyond its first tier gets those from `09-environment-setup` instead.
- Never applies Terraform locally, in any skill in this group — `7.2` submits via
  `4.5-open-terraform-pr` only.
