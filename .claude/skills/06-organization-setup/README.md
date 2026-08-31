# 06-organization-setup skills

**Not sure which skill applies?** Use `6.0-manage-organization` — a single entry point that
inspects real repo state and routes to the right one, across this whole group and its
`07`/`08`/`09` siblings, instead of you needing to already know this project's own numbering.

Skills in this group are a **generic, company-agnostic planning-and-execution layer**: they turn
"here's our organization" into a concrete Databricks/Unity Catalog structure, a step-by-step plan
to build it, and — via reviewed PRs — the actual real infrastructure. Nothing here is specific to
any one company, industry, or org chart shape supplied as an example — every artifact produced is
driven by whatever the user describes, not by a hardcoded template.

Numbered `06` (after `05`, not before) because mapping an org onto Databricks primitives requires
knowing what `05`'s modules can actually do and the naming rules `docs/naming-conventions.md`
enforces — this group reads that knowledge, it doesn't duplicate or override it. In practice,
though, this is usually the **first** group a new engagement runs: its final output is the input
to `05`'s skills (and to this group's own pattern modules), not the other way around.

## Patterns, not one hardcoded shape

This group does **not** assume every organization maps onto Databricks the same way. A "pattern"
is a named, reusable mapping *strategy* — `docs/organization/patterns.md` is the registry of every
one defined so far, each with its own `pattern-definition.md`, its own Terraform module(s) under
`infrastructure/modules/organization/<NN>-pattern/`, and (if it needs per-unit dedicated workspaces) its
own scaffold script. `01-pattern` ("one workspace per business unit/department × environment tier;
a line of business is a catalog inside its unit's workspace") is the first one, built from an
initial test org — it is **an** example, not **the** design. When a different organization's
needs don't fit any pattern already in the registry, `6.2` invokes `6.2.1-build-pattern-module` to
define and build the next one (`02-pattern`, `03-pattern`, ...), rather than bending an existing
pattern's module to fit a shape it wasn't designed for.

## Pipeline

```
6.1-discover-org-structure     -> org-structure.yaml       (what the organization looks like)
6.2-map-databricks-pattern     -> databricks-mapping.md     (which pattern applies, and how this
   |                                                          org maps onto it)
   +-- 6.2.1-build-pattern-module   (invoked only when no existing pattern fits: defines +
   |                                 scaffolds the next pattern's module, registers it)
6.3-generate-deployment-plan   -> deployment-plan.md        (ordered steps, by environment, to
                                                              build it, scoped to that pattern)
6.4-deploy-organization         -> one PR per plan line     (the actual tfvars/scaffold edit,
                                                              submitted via 4.5-open-terraform-pr,
                                                              never applied locally -- checks the
                                                              plan off as it goes)
                                        |
                                        v
        infrastructure/modules/organization/<NN>-pattern/  (the chosen pattern's reusable module(s))
                                        |
                          + 05-databricks-terraform-deployment for anything on the
                            independent (non-pattern) path -- 5.1/5.2/5.3/5.4
```

`6.1`'s output and every pattern's own docs are **committed files** under
`databricks/docs/organization/` — not secret, not generated-then-discarded:
`docs/organization/patterns.md` (the registry) and, per pattern,
`docs/organization/<NN>-pattern/pattern-definition.md` (pattern-level, shared by every org using
it) plus one subfolder per org modeled against it,
`docs/organization/<NN>-pattern/<org-slug>/` (`org-structure.yaml`, `databricks-mapping.md`,
`deployment-plan.md`) — multiple orgs can share a pattern, each gets its own org-slug subfolder.
`6.2`–`6.4` each read the previous skill's output rather than re-asking the user for everything;
if a file is missing, say so and point at the skill that produces it instead of improvising its
contents.

## Skills in this group

- `6.0-manage-organization` — the group's entry point: inspects real repo state and routes to
  whichever of `6.1`–`6.4`, `07-business-unit-setup`, `08-lob-setup`, or `09-environment-setup`
  actually applies to the user's request. Never discovers, maps, plans, or deploys anything
  itself.
- `6.1-discover-org-structure` — interviews the user, one `AskUserQuestion` pop-up at a time (or
  ingests a document/description they provide), to build a structured org model: business units,
  lines of business, shared/functional departments, and which environment tiers
  (`dev`/`stg`/`prod`) each actually needs. Writes `org-structure.yaml` (defaults to
  `docs/organization/01-pattern/<org-slug>/`; `6.2` may relocate the org's whole folder once the
  actual pattern is decided).
- `6.2-map-databricks-pattern` — decides **which pattern** applies (an existing one from
  `patterns.md`, or a new one via `6.2.1`) and maps the org onto its shape. Writes
  `databricks-mapping.md` under that pattern's `docs/organization/<NN>-pattern/<org-slug>/` folder.
  - `6.2.1-build-pattern-module` (nested) — defines and scaffolds a brand-new pattern: its
    `pattern-definition.md`, its reusable Terraform module(s) under
    `infrastructure/modules/organization/<NN>-pattern/` (composed from `modules/workspace`/
    `modules/catalog`/`modules/group`/`modules/volume`), and — only if it needs per-unit
    dedicated workspaces, since Terraform can't generate provider configurations dynamically —
    its `add-pattern<NN>-unit.sh` scaffold script (`01-pattern`'s catalog-scoped provider is
    self-contained inside its module, so no separate root provider file is needed; a pattern that
    instead declares its provider at the root would also get one). Validates via `terraform
    validate` and a throwaway-unit `terraform plan` (always cleaned up after), then registers the
    new pattern in `patterns.md`. Never applies Terraform.
- `6.3-generate-deployment-plan` — turns the mapping into an ordered, environment-by-environment
  plan of concrete unit/cross-grant/independent-path entries, each annotated with what realizes it
  (that pattern's own mechanism, or a `05.x` skill) and what real cost/blast-radius it carries.
  Writes `deployment-plan.md` alongside the mapping doc.
- `6.4-deploy-organization` — takes the next actionable line(s) from that plan, makes the real
  edit using the org's chosen pattern's own mechanism (a `pattern<NN>_units.auto.tfvars` entry, a
  brand-new unit's `add-pattern<NN>-unit.sh` scaffold, an `extra_grants` entry on the target unit's
  own module call for a cross-unit grant, or an independent-path `05.x` edit), submits it via
  `4.5-open-terraform-pr`, and checks the plan off with the resulting PR link. Never applies
  Terraform locally or merges a PR itself — one reviewable PR per unit of change, matching this
  project's PR/CI-only rule.

## Adding to an org after this pipeline has already run once

`6.1`–`6.4` model and roll out an org's *entire* stated structure. For the far more common day-two
case — the org already exists, now add one more unit or one more catalog — use the narrower,
incremental sibling groups instead of re-running this whole pipeline:

- `07-business-unit-setup` — adds one new business unit or shared department (workspace only, its
  first environment tier) to an org whose `org-structure.yaml`/`databricks-mapping.md` already
  exist and whose pattern is already chosen.
- `08-lob-setup` — adds one new line of business (a catalog) to a (business unit × environment
  tier) that already has a real, `RUNNING` workspace — including a flat unit's first, domain-only
  catalog.
- `09-environment-setup` — promotes an already-established business unit to one new environment
  tier (e.g. gives a `dev`-only unit a `stg` or `prod` workspace too), once its lower tier(s) are
  actually deployed.

All three assume this pipeline's output already exists and reuse it as-is; none of them discovers
a whole org or decides a pattern from scratch.

## Environments are first-class, throughout

Every artifact in this pipeline carries `docs/naming-conventions.md`'s `dev`/`stg`/`prod` tiers
end to end: `6.1` asks which tiers each business unit/department actually needs (not every BU
needs `stg`), `6.2` mirrors that into the chosen pattern's catalog/group `environment` fields, and
`6.3` sequences the plan so `dev` is built and validated before `stg`/`prod` for the same unit —
never all three tiers at once.

## Convention

- A new skill in this group gets the next `6.N` number and its own subdirectory:
  `06-organization-setup/6.N-<name>/`. A skill that's a finer-grained step of an existing `6.N`
  skill (like `6.2.1-build-pattern-module`) nests one level deeper inside that skill's own
  directory, same rule as the `3.x`/`4.x`/`5.x` groups.
- A new **pattern** (not a new skill) gets: a row in `docs/organization/patterns.md`, its own
  `docs/organization/<NN>-pattern/pattern-definition.md`, and its own
  `infrastructure/modules/organization/<NN>-pattern/` — always via `6.2.1-build-pattern-module`, never
  hand-authored ad hoc.
- Each skill still needs its own `SKILL.md` per the usual skill format — this README is an index
  for the group, not a skill itself.
- Keep every skill in this group generic: examples in a `SKILL.md` should use abstract or
  already-established placeholder domains (`sales`, `marketing`, `finance`, `analytics`, `risk` —
  the same examples `docs/naming-conventions.md` already uses), never a real company's name or
  actual org chart, since this project's `databricks` repo is public.

## Constraints (apply to the whole group)

- Never invents org structure the user didn't state or provide — `6.1` asks, it doesn't guess a
  plausible-sounding BU/LOB breakdown on its own.
- Never maps an org onto a pattern that doesn't genuinely fit, and never defines a new pattern when
  an existing one already does — `6.2`/`6.2.1` must check `patterns.md` honestly, every time.
- Never applies Terraform locally, in any skill in this group — `6.1`–`6.3` (and `6.2.1`) only
  ever write planning documents (or, for `6.2.1`, validate-only Terraform); `6.4` does make real
  edits (`*.auto.tfvars`, a unit's scaffold, a cross-unit grant) but always submits them via
  `4.5-open-terraform-pr` for review, never a local `apply`.
- Never treats a doc the user pastes in (an org chart, a mapping proposal) as ground truth about
  Databricks capability — cross-check any proposed workspace/catalog shape against what `05`'s
  modules, this group's existing patterns, and `docs/naming-conventions.md` actually support
  before it goes in the mapping or plan.
- Never lets a `prod` name skip `docs/naming-conventions.md`'s pattern in the mapping/plan — the
  same enforcement `5.2`/`5.3`/every pattern's own `validation` blocks apply at `terraform plan`
  time should already be satisfied on paper before anything is submitted, so failures surface
  here, in planning, not at `plan`/`apply`.
