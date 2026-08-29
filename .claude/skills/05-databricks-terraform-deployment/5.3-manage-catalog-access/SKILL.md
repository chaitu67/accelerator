---
name: 5.3-manage-catalog-access
description: Create Unity Catalog groups (with members) and grant them privileges on catalogs/schemas, via shared modules/group + root databricks_grants resources instantiated per-group and per-grant from committed groups.auto.tfvars and catalog_access.auto.tfvars maps -- gathers details, scaffolds (once), then deploys (plan, review, apply). Adding a group, member, or grant never requires touching CI workflow files or GitHub repo variables -- only these two committed tfvars files change. Use when the user asks to create a group, add users to a group, or grant catalog/schema access to a group.
---

# Manage Unity Catalog Access (databricks repo)

Third skill in the `05-databricks-terraform-deployment` group, alongside
[5.1-create-workspace](../5.1-create-workspace/SKILL.md) and
[5.2-create-unity-catalog](../5.2-create-unity-catalog/SKILL.md) — see [../README.md](../README.md).
Same standing pattern (reusable module(s) + `for_each` + committed `*.auto.tfvars`, no CI edits
per instance), applied to Unity Catalog groups and privilege grants.

**Scope**: creates account-level Databricks groups with members, and grants those groups
privileges (e.g. `USE_CATALOG`, `USE_SCHEMA`, `SELECT`, `MODIFY`, `CREATE_TABLE`) on a catalog as
a whole or on one schema within it. Does **not** create catalogs/schemas themselves (that's
`5.2`) and does **not** grant workspace login access (see "Known gap" below).

## Key difference from `5.1`/`5.2`: two provider scopes in one skill

- **Groups are account-scoped.** `databricks_group` and `databricks_group_member` use the
  `databricks.mws` aliased provider (same one `5.1`'s workspace/admin-assignment resources use),
  because group membership is an account-level concept, shared across every workspace attached to
  this account — not a per-workspace thing.
- **Grants are workspace-scoped**, same as `5.2`'s catalog/schema/storage-credential resources:
  `databricks_grants` uses the plain default `databricks` provider, so it operates against
  whichever one workspace that provider currently targets. Same gotcha as `5.2` — see its
  SKILL.md "Key difference" section — applies here unchanged; not re-litigated in this file.

Because of this, `deploy.sh` needs **both** an account-level OAuth login check (`5.1`'s style)
and an ordinary workspace-level auth check (`5.2`'s style) before it can plan/apply.

## Known gap: this does not grant workspace access

Being granted catalog/schema privileges does **not** by itself let someone log into or see the
workspace in the browser/SQL Editor/notebooks — that requires a separate workspace assignment
(same class of thing `5.1`'s `admin_emails` handles, but that path only assigns individual users
at `ADMIN` permission, not groups at ordinary `USER` permission). This skill doesn't touch
workspace assignment. If the group's members don't already have workspace access, say so plainly
rather than assuming catalog grants alone make them productive — that's a distinct, not-yet-built
capability (extending `modules/workspace`'s `admin_emails` idea to a group-based, non-admin
assignment) worth flagging back to the user, not quietly working around.

## Before starting

- Run `3.2-check-prerequisites` and `4.1-check-cicd-prerequisites` (or confirm both already
  passed).
- Confirm `account.auto.tfvars` exists (from `5.1-create-workspace`'s Phase 1) —
  `databricks_account_id` is shared and reused from there, same as `5.2`.
- Confirm at least one catalog already exists via `5.2-create-unity-catalog` — a grant needs a
  real `catalogs.auto.tfvars` entry to point at (`modules/catalog` must already be scaffolded).
- Confirm the same workspace-targeting question `5.2` asks has already been answered and still
  holds (grants land against whichever workspace the default `databricks` provider currently
  targets) — don't re-ask if `5.2` was just run in this same conversation and nothing changed.

## Phase 1: Gather details

Ask the user for these before touching any file. Groups and grants can be gathered together in
one conversation, or a group can be created now with grants added later (or vice versa, if the
group already exists) — same "edit the committed tfvars again" idiom as `5.1`/`5.2`.

**For each group:**
- **A short group slug** (e.g. `data-engineers`) — used as the `groups` map key and the group's
  account-level display name.
- **Member emails** — existing Databricks account users only; this skill doesn't create users.
  Confirm each email is a real account user before writing it in (a typo silently fails at
  `apply` with a "user not found" error from the `databricks_user` data source).

**For each grant:**
- **Which group** (must already have an entry in `groups.auto.tfvars`, from this conversation or
  a prior one).
- **Which catalog** (must already have an entry in `catalogs.auto.tfvars` via `5.2`).
- **Catalog-level or schema-level?** If schema-level, which schema (must already exist in that
  catalog's `schemas` list).
- **Which privileges** — common ones: `USE_CATALOG`/`USE_SCHEMA` (required just to see/traverse
  into it), `SELECT`, `MODIFY`, `CREATE_TABLE`, `CREATE_SCHEMA` (catalog-level only). Don't guess
  a "reasonable default" set — ask what access the group actually needs; over-granting is a real
  security decision, not a formality.

Once confirmed, write/update entries in `databricks/infrastructure/groups.auto.tfvars` and
`databricks/infrastructure/catalog_access.auto.tfvars` (create either file if it doesn't exist
yet — no `.example` to copy from; the shape is documented here and in `modules/group/variables.tf`
/ root `variables.tf`'s `catalog_grants` description). Both files are **committed, not
gitignored** — none of this data is secret (privilege names and group membership emails aren't
credentials).

## Phase 2: Implement

```
bash .claude/skills/05-databricks-terraform-deployment/5.3-manage-catalog-access/implement.sh
```

Idempotent — scaffolds `modules/group/{versions,variables,main,outputs}.tf`, root `groups.tf`
(the group `for_each` module block), root `catalog_access.tf` (the `databricks_grants` `for_each`
resources), the `groups`/`catalog_grants` variables in `variables.tf`, and a `group_names` output
in `outputs.tf`. Never overwrites a file that already exists, so **after the first run, this step
is a no-op** — adding group #2 or grant #2+ only means editing the committed tfvars files.

Requires `modules/catalog/main.tf` to already exist (errors out with a pointer to
`5.2-create-unity-catalog` if not) — `catalog_access.tf`'s grants reference `module.catalog[...]`
outputs directly.

## Phase 3: Deploy

Same two options as `5.1`/`5.2`, same discipline (never auto-apply, human reviews the plan
first):

**A. Through the CI/CD pipeline** — commit whatever Phase 2 scaffolded (first run only) plus the
Phase 1 edits to `groups.auto.tfvars`/`catalog_access.auto.tfvars`, push, open a PR.
`terraform-plan.yml` posts the plan automatically — no repo-variable or workflow changes needed.
Merging triggers `terraform-apply.yml`.

**B. Directly, from this machine**:

```
bash .claude/skills/05-databricks-terraform-deployment/5.3-manage-catalog-access/deploy.sh plan
```

Checks **both** account-level Databricks auth (triggers the same
`databricks auth login --host https://accounts.cloud.databricks.com ...` dance as `5.1`'s
deploy.sh if not already logged in — an ACCOUNT ADMIN must do this, since group creation is an
account-level operation) **and** ordinary workspace-level auth (`3.2.2-authenticate-databricks`,
same as `5.2`), then `terraform init` + `plan -out=tfplan`. Show the plan to the user and get
explicit confirmation. Once confirmed:

```
bash .claude/skills/05-databricks-terraform-deployment/5.3-manage-catalog-access/deploy.sh apply
```

Applies exactly the reviewed `tfplan`, then prints `group_names` (map keyed by each group's
slug) along with every other output already defined.

## Adding group/grant #2 and beyond

Once the module exists (Phase 2 has run once), adding another group or grant is: Phase 1's
conversation again, add a new entry to the already-existing `groups.auto.tfvars` and/or
`catalog_access.auto.tfvars`, then Phase 3 as usual. `implement.sh` has nothing left to do
(confirm it reports "Nothing to do"). No `.github/workflows/*.yml` edit and no `gh variable set`
at any point, for any number of groups or grants.

## Constraints

- Never grants workspace login/UI access — see "Known gap" above. Say so rather than assuming a
  catalog grant is sufficient for someone to actually use the workspace.
- Never creates Databricks account users — `member_emails` in `groups.auto.tfvars` must already
  be real account users; this skill only looks them up (via the `databricks_user` data source),
  never provisions them.
- Never applies without a human-reviewed `plan` step first, whether local (`deploy.sh apply`
  hard-refuses without a saved `tfplan`) or via the pipeline.
- Never guesses which privileges a group needs — always ask explicitly in Phase 1; don't default
  to a broad set (e.g. `ALL_PRIVILEGES`) "to be safe."
- Never guesses which workspace grants land in — same rule as `5.2`, not re-derived here.
- `implement.sh` never overwrites existing files and never writes real per-group/per-grant values
  — those only ever go into the committed `groups.auto.tfvars` / `catalog_access.auto.tfvars`,
  directly, per Phase 1.
- Each `catalog_grants` entry targets exactly one catalog or one schema (never both at once) —
  `databricks_grants` takes exactly one securable argument; a group needing both catalog-level
  and schema-level privileges gets two separate map entries.
