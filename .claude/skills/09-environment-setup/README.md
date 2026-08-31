# 09-environment-setup skills

Skills in this group promote a business unit or shared department to **one new environment tier**
— giving a unit that's only deployed at `dev` a `stg` (or `prod`) workspace too, one tier at a
time. Under `01-pattern` (and any pattern with dedicated per-unit workspaces), each (business unit
× environment tier) is its own separate Terraform unit — its own `unit_key` (`<bu_key>_<env>`),
own workspace, own scaffolded file (confirmed against `meridian-financial/databricks-mapping.md`'s
`retail-dev`/`retail-stg`/`retail-prod`: three distinct workspaces for one BU). `7.2` deploys a
brand-new unit's *first* tier only — this group is what deploys every tier after that.

Numbered `09` (after `08`) because, like `07`/`08`, it assumes the org already exists
(`org-structure.yaml`/`databricks-mapping.md` present, pattern already chosen) — it just fills in
the next slice of a shape the org already asked for.

## Scope: workspace only, not catalogs

Same split as `07-business-unit-setup`: this group creates the new tier's **workspace** and
nothing else. The new tier's LOB catalogs (including a flat unit's one domain-only catalog) are
`08-lob-setup`'s job, run once per existing LOB, once the new tier's workspace is `RUNNING` — a
catalog that already exists at a lower tier does **not** automatically exist at the new one; it
has to be created there too.

## Pipeline

```
9.1-discover-environment  -> confirms (or adds) the target tier on the unit's org-structure.yaml
                             entry, verifies dev-before-stg-before-prod ordering against what's
                             actually deployed, updates databricks-mapping.md
9.2-deploy-environment    -> add-pattern<NN>-unit.sh scaffold + pattern<NN>_units.auto.tfvars
                             entry for the new tier's own unit_key (<bu_key>_<env>, host null,
                             catalogs {}), submitted via 4.5-open-terraform-pr
                                     |
                                     v
                    08-lob-setup, once per existing LOB, once this tier reports RUNNING
```

## Skills in this group

- `9.1-discover-environment` — confirms which unit and which new tier (adding the tier to that
  unit's `org-structure.yaml` `environments` list first, if it wasn't already requested there),
  verifies every lower tier that unit needs is already deployed (`dev` before `stg` before
  `prod`), and updates `databricks-mapping.md` noting the new tier's planned workspace. Requires
  the target org's `org-structure.yaml`/`databricks-mapping.md` and the unit itself to already
  exist. Never touches lines of business, never edits Terraform.
- `9.2-deploy-environment` — takes the tier `9.1` just confirmed and actually creates its
  workspace: runs that org's pattern's `add-pattern<NN>-unit.sh <bu_key>_<env>` scaffold, adds the
  workspace-only `pattern<NN>_units.auto.tfvars` entry (`host = null`, `catalogs = {}`), and
  submits via `4.5-open-terraform-pr`. Never bundles catalogs into this PR, never applies
  Terraform locally.

## Before running anything in this group

Confirm the target business unit already exists in `org-structure.yaml`/`databricks-mapping.md`
(from `6.1`/`6.2`, or `7.1`) — if it doesn't exist at all yet, point at `07-business-unit-setup`
instead; this group only ever adds a *tier* to a unit that already has at least one deployed.

## Convention

- Each skill here still needs its own `SKILL.md` per the usual skill format — this README is an
  index for the group, not a skill itself.
- Keep examples generic, never a real company's name or org chart — same rule as
  `06-organization-setup`/`07-business-unit-setup`/`08-lob-setup`, since `databricks` is public.

## Constraints (apply to the whole group)

- Never creates a business unit from scratch — that's `07-business-unit-setup`'s (or `06`'s) job;
  this group only ever adds a tier to a unit that already exists and already has a lower tier
  deployed.
- Never deploys `stg` or `prod` for a unit before its lower tier(s) are actually deployed (merged
  and applied, not just planned) — `9.1` is the enforcement point for this, same as `6.3`'s
  ordering rule for a whole-org rollout.
- Never creates a line-of-business catalog for the new tier, even a flat, no-LOB-split one, and
  never assumes a catalog that exists at a lower tier already exists at the new one — both always
  go through `08-lob-setup`, once per existing LOB, once the new tier is `RUNNING`.
- Never applies Terraform locally, in any skill in this group — `9.2` submits via
  `4.5-open-terraform-pr` only.
