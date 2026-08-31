---
name: 6.1-discover-org-structure
description: Interview the user, one AskUserQuestion pop-up at a time (or ingest an org chart / structure document they provide), to build a structured, generic org model -- business units, lines of business, shared functional departments, and which environment tiers (dev/stg/prod) each actually needs -- and write it to databricks/docs/organization/<pattern>/<org-slug>/org-structure.yaml. Use when the user wants to design, model, or document an organization's structure as a precursor to building Databricks infrastructure for it.
---

# Discover organization structure (databricks repo)

First skill in the `06-organization-setup` group — see [../README.md](../README.md). Produces
the org model that `6.2-map-databricks-pattern` and `6.3-generate-deployment-plan` both build on.

**Scope**: this skill only discovers and records structure. It does not decide anything about
Databricks (no workspace/catalog/group naming happens here — that's `6.2`) and does not touch any
Terraform file.

## Before starting

- Confirm `databricks/docs/naming-conventions.md` exists (from the sibling `databricks` repo) —
  read it if you haven't in this conversation, since the environment tiers and domain vocabulary
  this skill gathers must line up with what `6.2` will later validate against.
- Skim `databricks/docs/organization/patterns.md` if it exists — not to pick a pattern (that's
  `6.2`'s job, not this skill's), just so you know which org-instance folders already exist under
  each pattern (`docs/organization/<N>-pattern/<org-slug>/`). This skill defaults to writing under
  `databricks/docs/organization/01-pattern/<org-slug>/` (today's only defined pattern) — `6.2` may
  relocate the whole org-slug folder into a different pattern's directory if it turns out this org
  needs a pattern that doesn't exist yet. `<org-slug>` comes from Phase 1 item 1 (organization
  identity) — every org gets its own subfolder, even when multiple orgs end up sharing the same
  pattern; never write two orgs' files into one flat folder.
- Check whether an `org-structure.yaml` for this org's slug already exists (under whichever
  pattern folder it currently lives in). If it does, this is an **update**, not a fresh discovery:
  show the user the current model and ask what's changing, rather than re-asking everything from
  scratch.

## Phase 1: Gather the org model

This is a conversation, not a form, and not a batch questionnaire either: **ask one question at a
time, via the `AskUserQuestion` tool (a pop-up), and wait for the answer before asking the
next.** Never send the whole list below as plain chat text in one message, and never substitute
plain conversational text for the pop-up on any Phase 1 item — that's what makes the interview
consistent to answer, not just less rushed. For a field with natural common choices (environment
tiers, cloud region, a role vocabulary), offer those as the pop-up's options; for anything
genuinely open-ended (organization name, a BU/LOB/department's actual name or slug, sensitivity
notes), offer a couple of illustrative examples as options and rely on the tool's built-in "Other"
free-text choice for the real answer — the interaction is still the pop-up either way. Follow up
on each answer (plain chat is fine for a clarifying follow-up, not for the next Phase 1 item
itself) where the shape is unclear before moving on, and don't force-fit an org that doesn't
cleanly have all these layers.

The one exception: if the user hands you a document instead (an org chart, a corporate-structure
writeup, a pasted description), extract all of the fields below from it in one pass — that's them
giving you everything at once, not you rushing them — but still confirm your extraction back to
them, field by field or as one summary, before writing anything. Documents like that are often
aspirational or illustrative, not literal, so confirm rather than transcribing blindly.

Ask, one at a time, in order. Note the shape: **identity first, then the full org structure (BUs,
LOBs, shared departments, sensitivity notes), then infrastructure scope (cloud/regions/tiers), with
environments last in one consolidated pass** — asking "which tiers does this BU need" while you're
still discovering the BU list forces you to revisit units you've already moved past; asking it
once, after every BU/department is already known, is simpler for both of you and is what item 9
below is for. Structure is gathered before cloud/region/tier scope so the org's actual shape is
settled before any infrastructure-flavored question comes up.

1. **Organization identity.** A short name/slug for the organization being modeled (used only as
   a label in the YAML, never as a literal Databricks resource name — that happens in `6.2`). If
   the user is working from a real company's public org chart as a *reference/example* for shape
   rather than modeling that company directly, say so in the `name` field explicitly (e.g.
   `"acme-financial (shape inspired by a public reference, not modeling a real company)"`) rather
   than silently adopting the real name — this project's `databricks` repo is public.
2. **The list of business units (BUs)** — just names/slugs at this point, not their environment
   tiers yet (that's item 9). A short slug per BU (lowercase, will become a naming-convention
   `domain` segment in `6.2` — same character rules as `docs/naming-conventions.md`'s catalog
   `domain`: starts with a letter, lowercase alphanumeric).
3. **For each BU in that list, one at a time**: its display name, and whether it splits into lines
   of business (and if so, their slugs/names — not every BU needs LOB-level granularity; a small
   BU can skip straight to schemas in `6.2`). Work through the whole BU list before moving to the
   next item — still no environment-tier question here, that's item 9.
4. **Shared/functional departments** that cut across BUs rather than belonging to one (e.g. a
   platform engineering, compliance/audit, or finance team that needs read/write across multiple
   BUs' data). Ask for the list first, then go through each one (display name, which BUs it needs
   access across) the same one-at-a-time way as item 3 — again, no environment-tier question yet.
   Record these separately from BUs — they get modeled as cross-cutting groups in `6.2`, not as
   another BU.
5. **Any stated data-sensitivity or isolation requirements** per BU/LOB/department (e.g. "this
   unit's data must never be queryable by that unit," "this dataset has PII"). Record these
   verbatim as flags on the relevant node — `6.2` will note where the project can enforce them
   today (catalog/schema-level grants) versus where it can't yet (row/column-level ABAC masking is
   reserved vocabulary in naming-conventions.md, not an implemented mechanism — say so rather than
   promising it).
6. **Cloud + regions in scope.** This project's `05` skills are AWS-only today (`5.1`'s module is
   AWS-specific) — if the user describes a multi-cloud org, note that only the AWS portion is
   buildable via this project's current skills, the rest is documentation-only. If more than one
   region is in scope, don't stop here — which tier(s) use which region is item 8, right after
   environment tiers are known.
7. **Environment tiers actually in use, org-wide.** Confirm the org uses some subset of
   `dev`/`stg`/`prod` (per naming-conventions.md) — don't assume all three; some orgs skip `stg`
   entirely, some sandbox environments don't map to any of the three cleanly (ask how to classify
   those rather than inventing a fourth tier).
8. **Environment → region mapping** (only ask if item 6 named more than one region; skip this item
   entirely for a single-region org — every tier obviously uses that one region). For each
   environment tier from item 7, which region it deploys to. This is real, load-bearing data —
   every workspace `6.2` maps onto later needs one concrete `aws_region`, and there is no default
   to fall back on if this is never asked. A specific BU/department needing a *different* region
   than this org-wide mapping is a per-unit override, captured in item 9 alongside its environment
   tiers, not invented here.
   - If the user mentions a **DR/failover region** for any tier (a second region alongside the
     primary), don't assume what that means — ask specifically whether it needs a full duplicate
     (its own catalogs too, region-qualified naming — a real scope expansion this pipeline doesn't
     build today, since Unity Catalog metastores are region-bound: a workspace in a different
     region can't share the primary region's catalogs) or a **workspace-only standby** (no
     catalogs created here, ever — data replication to that region is a separate concern outside
     `06-organization-setup`). The workspace-only shape needs no new mechanism — `01-pattern`
     already supports a workspace with `catalogs = {}`. Record which tiers get a DR standby and
     which region, e.g. as `dr: { region: <region>, tiers: [<tier>, ...] }` — omit entirely if no
     DR requirement was stated.
9. **Now, the consolidated environments pass**: with every BU and shared department already known
   from items 2–4, go through the full list — one at a time, same as before — and confirm which
   environment tiers *each one specifically* needs (a small internal-tools BU might only ever need
   `dev` — don't assume the org-wide set from item 7 applies uniformly). If item 8 established more
   than one region is in play, this is also where a unit's *region override* would come up (rare —
   only if the user states one; don't ask "does this unit need a different region" as a matter of
   course, that's inventing a question item 8 didn't already justify).

Don't invent BUs, LOBs, or departments the user didn't mention.

## Phase 2: Write the org model

Write (or update) `databricks/docs/organization/01-pattern/<org-slug>/org-structure.yaml` (default
location — see "Before starting"; `6.2` may move this org's whole folder into a different
pattern's directory once it determines which pattern actually applies):

```yaml
organization:
  name: <string>                    # label only, see Phase 1 item 1
  cloud: aws
  regions: [<region>, ...]          # every region in scope, from item 6
  environment_tiers: [dev, stg, prod]   # subset actually in use org-wide, from item 7
  environment_regions:              # from item 8 -- REQUIRED whenever regions has >1 entry;
    dev: <region>                   # omit this whole map entirely for a single-region org
    stg: <region>
    prod: <region>
  dr:                                # optional; omit entirely if no DR requirement was stated
    region: <region>                # the standby region, from item 8's DR sub-question
    tiers: [<tier>, ...]             # which environment tier(s) get a workspace-only standby
                                      # there -- workspace only, no catalogs via this pipeline;
                                      # "full duplicate" (its own catalogs, region-qualified
                                      # naming) is a distinct, larger ask this pipeline doesn't
                                      # build -- don't record it here if that's what was meant

business_units:
  - key: <slug>                     # e.g. sales, marketing, finance, analytics, risk
    name: <display name>
    environments: [dev, prod]       # subset of environment_tiers this BU needs, from item 9
    region_overrides: {}            # only if item 9 surfaced one, e.g. { prod: <region> };
                                     # omit entirely otherwise -- don't invent one
    lines_of_business:
      - key: <slug>                 # optional level; omit list entirely if BU has no LOB split
        name: <display name>
    sensitivity_notes: []           # verbatim flags from Phase 1 item 5, or omit if none

shared_departments:
  - key: <slug>                     # e.g. platform, risk_compliance, finance_ops
    name: <display name>
    environments: [<tiers>]         # from item 9
    region_overrides: {}            # same as business_units, only if stated
    scope: [<business_unit key>, ...]   # which BUs this department needs access across
    sensitivity_notes: []
```

This file is **committed, not gitignored** — none of this is secret, same as every `*.auto.tfvars`
file `05`'s skills produce. Create `databricks/docs/organization/` if it doesn't exist yet.

## Constraints

- Never asks more than one Phase 1 question in a single message, except when extracting from a
  document the user already handed over — one question, wait for the answer, then the next.
- Never asks a Phase 1 question as plain chat text — always via `AskUserQuestion`, even when the
  field is open-ended (offer illustrative example options and rely on "Other" for the real
  answer).
- Never proceeds to `6.2`'s Databricks-mapping questions in the same breath — this skill's job
  ends at a confirmed org model, not a resource plan.
- Never writes a BU/LOB/department the user didn't state, and never drops one they did state for
  being "too small to matter" — completeness here is what makes `6.2`/`6.3` trustworthy later.
- Never adopts a real company's name as the literal `organization.name` when the user is clearly
  using it as an illustrative reference rather than describing their own org — ask which it is if
  unclear, per Phase 1 item 1.
- Never silently assumes all three environment tiers apply everywhere — ask per BU/department
  (item 9, once the full unit list is known — not interleaved into item 3/4's structure questions).
- Never leaves `environment_regions` unset when more than one region is in scope (item 6) — every
  workspace `6.2` maps onto later needs one concrete region, and there is no sensible default to
  silently fall back on.
