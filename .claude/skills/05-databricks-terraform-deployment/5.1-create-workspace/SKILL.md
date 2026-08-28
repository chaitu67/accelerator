---
name: 5.1-create-workspace
description: Provision a Databricks-on-AWS workspace (Databricks-managed VPC) via Terraform, using a shared modules/workspace module instantiated per-workspace from a committed workspaces.auto.tfvars map -- gathers the required details first, then scaffolds the module (once) and adds a map entry, then deploys (plan, review, apply) against the S3-backed remote state set up by 04-github-cicd. Adding a second (or Nth) workspace never requires touching CI workflow files or GitHub repo variables -- only this one committed tfvars file changes. Use when the user asks to create/provision/stand up a new Databricks workspace via Terraform.
---

# Create Workspace (databricks repo)

First skill in the `05-databricks-terraform-deployment` group — see [../README.md](../README.md)
for why this runs *after* `03-terraform-setup` and `04-github-cicd`, not right after the
Terraform project is scaffolded. Where `3.1-scaffold-infrastructure` sets up the Terraform
project shell, `3.2-check-prerequisites` audits the environment, and `04-github-cicd` gets a
remote S3 backend + GitHub Actions pipeline in place, this skill does the actual work: create a
new Databricks workspace on AWS with a Databricks-managed VPC (Databricks creates and manages
the VPC itself — no pre-existing VPC/subnets required). Customer-managed VPC is out of scope;
see Constraints.

**The pattern**: workspace resources live in a single reusable `modules/workspace` Terraform
module, instantiated via `for_each` over a `workspaces` map variable (see root `variables.tf`
and `workspaces.tf`). The map's actual values live in a **committed, non-secret**
`workspaces.auto.tfvars` (Terraform auto-loads `*.auto.tfvars` files automatically, locally and
in CI — no `TF_VAR_*`, no `gh variable set`, no workflow YAML edit needed). Creating workspace
\#2, #3, etc. is just adding a map entry to that one file, opening a PR, and merging — this skill
never needs to touch `.github/workflows/*.yml` or GitHub repo variables again after the first
run. (This replaces an earlier per-workspace-variable pattern that caused two real CI failures
during this project's own first workspace creation — see `04-github-cicd/4.4-create-workflows`'s
SKILL.md for that history.)

Three phases, always in this order, never skipped or reordered:

1. **Gather details** — a conversation, not a script (see below).
2. **Implement** — scaffold the module (`implement.sh`; a no-op after the first workspace).
3. **Deploy** — plan, let the user review, then apply (`deploy.sh`, or through the CI/CD
   pipeline — see Phase 3).

## Before starting

Run `3.2-check-prerequisites`'s `check.sh` **and** `4.1-check-cicd-prerequisites`'s `check.sh`
first (or confirm both already passed in this session). The second one matters here
specifically: this skill's first-ever run is the *first* real `terraform apply` for this
project, and the whole point of running `04-github-cicd` beforehand is that state is already
living in the S3 backend before that first apply happens — there's no local-state deployment to
migrate later. If `4.1` still reports the backend as local, run `4.2-setup-remote-backend`
before continuing here.

This skill additionally needs **account-level** Databricks auth (see Deploy below), which
neither `3.2` nor `4.1` check — that's specific to workspace *creation*, not day-to-day
Terraform against an existing workspace.

## Phase 1: Gather details

Ask the user for these before touching any file — don't guess or silently default anything
that has real consequences (money, naming, which AWS account). Use `AskUserQuestion` for the
ones with real tradeoffs; free-text/confirm for the rest:

- **Workspace display name** and **deployment name** (used to prefix the account-level
  resource names — credentials/storage config — not the URL; see "Known: deployment_name
  usually isn't usable" below for why). Suggest one derived from the display name, confirm
  with the user. The actual workspace URL is auto-assigned by Databricks and only known after
  apply (the `workspace_urls` output, keyed by the map slug you choose below).
- **A short map key/slug** for this workspace (e.g. `workshop-workspace`) — used as the
  `workspaces` map key, and to default `deployment_name`/`cross_account_role_name` if the user
  doesn't want to set those explicitly.
- **AWS region** — default to the existing `aws_region` in `terraform.tfvars`.
- **Root S3 bucket name** — must be globally unique across **all of S3**, not just this AWS
  account. Suggest `<deployment-name>-dbfs-root-<random-suffix>` and confirm.
- **Cross-account IAM role name** — suggest a default (`databricks-<deployment-name>-crossaccount`)
  unless the user wants to reuse an existing cross-account role from a prior workspace in the
  same AWS account (credentials/storage configs can be shared across workspaces).
- **Pricing tier** — STANDARD / PREMIUM / ENTERPRISE. Default to PREMIUM (needed for most
  governance features) but ask rather than assume.
- **Databricks account ID** — from the Account Console (top right), or
  `grep account_id ~/.databrickscfg` if the user has ever logged in at the account level
  before. **Always confirm this explicitly with the user** even if a value is discoverable —
  creating a workspace under the wrong account is a real, costly mistake. Only needed once —
  every workspace in the map shares the same account.
- **Confirm the AWS identity**: run `aws sts get-caller-identity` and show the user the account
  it resolves to, so they can confirm the new workspace's AWS resources (IAM role, S3 bucket)
  land in the right AWS account — the same account `4.3-configure-github-oidc` already
  confirmed and scoped CI's role to.

Once all of these are confirmed, write them into `databricks/infrastructure/workspaces.auto.tfvars`
as a new entry in the `workspaces` map (create the file if it doesn't exist yet — there is no
`.example` to copy from; the shape is documented directly in this SKILL.md and in the file's own
comments once created). This file is **committed, not gitignored** — none of this data is secret
(names/regions/bucket names/tiers are already visible in every `terraform plan`/PR comment).
The first time only, also write `databricks_account_id` into
`databricks/infrastructure/account.auto.tfvars` (also committed). `databricks_account_profile`
(a local dev-machine preference, not needed by CI) can stay in the gitignored `terraform.tfvars`,
defaulting to `ACCOUNT` unless the user wants a different profile name.

## Phase 2: Implement

```
bash .claude/skills/05-databricks-terraform-deployment/5.1-create-workspace/implement.sh
```

Idempotent — scaffolds `mws_provider.tf` (account-level provider + its 2 variables),
`modules/workspace/{versions,variables,main,outputs}.tf` (the reusable workspace module), root
`workspaces.tf` (the `for_each` module block), and the `workspaces` variable in `variables.tf` +
aggregated outputs in `outputs.tf` — all inside `databricks/infrastructure/`. Never overwrites a
file that already exists, so **after the first workspace, this step is a no-op**: the module and
wiring are already there, and adding workspace #2+ only needs Phase 1's edit to
`workspaces.auto.tfvars`. Only writes generic resource/variable definitions, never the actual
values gathered in Phase 1 (those go into the two committed `.auto.tfvars` files, handled
directly per Phase 1, not by this script).

Uses the `databricks` provider's own `databricks_aws_assume_role_policy`,
`databricks_aws_crossaccount_policy`, and `databricks_aws_bucket_policy` data sources to
generate the IAM/S3 policies Databricks requires, rather than hand-maintained policy JSON —
these track Databricks' actual requirements instead of going stale.

## Phase 3: Deploy

Two ways to run this, now that `04-github-cicd` exists — pick based on how the user wants to
work, but either way state lands in the same S3 backend:

**A. Through the CI/CD pipeline (recommended, now that it exists)** — commit whatever Phase 2
scaffolded (first workspace only) plus the Phase 1 edits to `workspaces.auto.tfvars` (and
`account.auto.tfvars`, first time only), push to a branch, and open a PR. `terraform-plan.yml`
runs automatically and posts the plan as a PR comment for review — no repo-variable or workflow
changes needed even though this is real data reaching CI, because Terraform auto-loads the
committed `.auto.tfvars` files itself. Merging to `main` triggers `terraform-apply.yml`, which
pauses for approval if the `production` GitHub Environment has required reviewers configured,
then applies.

**B. Directly, from this machine** (useful for a fast local iteration loop, or if the pipeline
isn't wired up the way the user wants yet):

```
bash .claude/skills/05-databricks-terraform-deployment/5.1-create-workspace/deploy.sh plan
```

- Checks account-level Databricks auth first (`databricks auth profiles`); if not
  authenticated, runs `databricks auth login --host https://accounts.cloud.databricks.com
  --account-id <id> --profile <databricks_account_profile>` — a browser-based OAuth login,
  safe to run directly. **This must be done by an account admin**, not just a workspace
  user/admin — if it fails, that's the most likely reason.
- Warns (doesn't block) if any workspace's root bucket name in `workspaces.auto.tfvars` already
  exists and is reachable — S3 bucket names are globally unique, so a collision needs a
  different name.
- Runs `terraform init` and `terraform plan -out=tfplan`, saving the plan to
  `databricks/infrastructure/tfplan`. Since `backend.tf` already points at the S3 backend
  (from `4.2-setup-remote-backend`), this reads/writes the same shared state the pipeline uses
  — no separate local state to reconcile later.

**Show the plan output to the user and get explicit confirmation before applying** — this
creates real, billed AWS and Databricks infrastructure (EC2 capacity once clusters run, an S3
bucket, an IAM role, a workspace). Never auto-apply. Once confirmed:

```
bash .claude/skills/05-databricks-terraform-deployment/5.1-create-workspace/deploy.sh apply
```

Applies exactly the reviewed `tfplan` (refuses to run if no saved plan exists — forces the
plan-then-review-then-apply order), then prints the `workspace_urls`/`workspace_statuses` map
outputs (keyed by each workspace's map slug). Workspace creation takes several minutes after
`apply` succeeds — check `workspace_statuses` or the Account Console until it reads `RUNNING`.

## Adding workspace #2 and beyond

Once the module exists (Phase 2 has run once for this project), adding another workspace is:
1. Phase 1's conversation again, for the new workspace's details.
2. Add a new entry to the `workspaces` map in the already-existing `workspaces.auto.tfvars` —
   Phase 2's `implement.sh` has nothing left to do (confirm it reports "Nothing to do").
3. Phase 3 as usual (PR + merge, or `deploy.sh plan`/`apply`).

**No `.github/workflows/*.yml` edit and no `gh variable set` at any point in this flow, ever,
for any number of workspaces.** If a future workspace genuinely needs a new *kind* of input this
module doesn't support yet (e.g. customer-managed VPC), that's a module change (add a variable +
resource to `modules/workspace`), not a CI change — CI already forwards nothing per-workspace.

## Known IAM propagation delay

`databricks_mws_credentials` can fail on `apply` with `"Failed credential validation checks:
please use a valid cross account IAM role..."` even though the role/policy were just created
successfully — Databricks validates the role by actually assuming it, and IAM is eventually
consistent, so the assume-role can fail for a few seconds right after the policy is attached.
`modules/workspace/main.tf` includes a `time_sleep.iam_propagation` resource (30s, depends on
the role policy) that `databricks_mws_credentials` depends on, to absorb this. If it still
fails, the role/policy are already in state — just re-run `deploy.sh plan` then `deploy.sh
apply` again (or re-run the pipeline), nothing needs to be recreated.

## Known: deployment_name usually isn't usable

`databricks_mws_workspaces` errors with `"Deployment name cannot be used until a deployment
name prefix is defined"` on any account that doesn't have a deployment name prefix configured
(an account-level setting only Databricks can set — most accounts don't have one, evidenced by
an existing workspace URL looking like `dbc-<random>.cloud.databricks.com` rather than a chosen
name). Because of this, `modules/workspace/main.tf` deliberately does **not** set
`deployment_name` on `databricks_mws_workspaces` — Databricks auto-assigns the URL instead, read
back via the `workspace_urls` output after apply. The module's `deployment_name` variable still
exists and is used, but only to prefix the account-level resource *names* (`credentials_name`,
`storage_configuration_name`), not the URL.

## Known benign warning

`terraform plan`/`apply` prints a deprecation warning that `account_id` on the `databricks_mws_*`
resources "should be set as part of the Databricks Config, not in the resource." Ignore it —
in the provider version pinned by `versions.tf`, `databricks_mws_storage_configurations` and
`databricks_mws_workspaces` still error with "Missing required argument" if `account_id` is
removed from the resource, despite the warning. Confirmed by testing both ways; the module
keeps the explicit `account_id = var.databricks_account_id` deliberately.

## Constraints

- **Databricks-managed VPC only.** Customer-managed VPC (bring-your-own VPC/subnets/security
  groups) is not implemented — if the user needs that, it's a distinct set of AWS networking
  resources (`aws_vpc`, subnets, NAT gateway, `databricks_mws_networks`) this skill doesn't
  scaffold. Say so rather than improvising a partial version.
- Never applies without a human-reviewed `plan` step first, whether local (`deploy.sh apply`
  hard-refuses to run without a saved `tfplan`) or via the pipeline (`terraform-apply.yml` only
  runs after `terraform-plan.yml`'s PR comment has been reviewed and merged).
- Never guesses or silently defaults the Databricks account ID, workspace naming, or which AWS
  identity is active — always confirmed with the user in Phase 1, since getting any of these
  wrong creates real infrastructure under the wrong account.
- `implement.sh` never overwrites existing files, matching `3.1-scaffold-infrastructure`'s
  convention, and never writes real per-workspace values — those only ever go into the two
  committed `.auto.tfvars` files, directly, per Phase 1.
- `root_bucket_force_destroy` defaults to `false` (AWS's own safe default) in each map entry —
  only set `true` if the user explicitly wants easy teardown of a disposable workspace, since
  `true` lets `terraform destroy` delete a non-empty bucket's data.
- Never runs this skill before `04-github-cicd`'s prerequisites are confirmed (see "Before
  starting") — running it earlier defeats the entire reason for that group's ordering: clean,
  S3-managed state from the first real `apply`.
- If refactoring an existing, already-applied single-workspace `workspace.tf` into this module
  pattern (rather than starting fresh), `moved` blocks are required to re-address the live
  resources into the module instance — landing the module, the `moved` blocks, and the matching
  `workspaces.auto.tfvars` entry in the **same** `terraform plan`/`apply`, never split across
  separate applies (splitting them makes Terraform see the old resources as deleted from
  config and plan to destroy the live infrastructure). Verify locally with `terraform plan`
  showing `0 to add, 0 to change, 0 to destroy` (all resources annotated as moved) before ever
  pushing.
