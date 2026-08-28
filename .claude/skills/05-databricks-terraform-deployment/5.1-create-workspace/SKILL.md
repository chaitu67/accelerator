---
name: 5.1-create-workspace
description: Provision a brand-new Databricks-on-AWS workspace (Databricks-managed VPC) via Terraform - gathers the required details first, then scaffolds the Terraform resources, then deploys (plan, review, apply) against the S3-backed remote state set up by 04-github-cicd. Use when the user asks to create/provision/stand up a new Databricks workspace via Terraform.
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

Three phases, always in this order, never skipped or reordered:

1. **Gather details** — a conversation, not a script (see below).
2. **Implement** — scaffold the Terraform resources (`implement.sh`).
3. **Deploy** — plan, let the user review, then apply (`deploy.sh`, or through the CI/CD
   pipeline — see Phase 3).

## Before starting

Run `3.2-check-prerequisites`'s `check.sh` **and** `4.1-check-cicd-prerequisites`'s `check.sh`
first (or confirm both already passed in this session). The second one matters here
specifically: this skill is the *first* real `terraform apply` for this project, and the whole
point of running `04-github-cicd` beforehand is that state is already living in the S3 backend
before that first apply happens — there's no local-state deployment to migrate later. If `4.1`
still reports the backend as local, run `4.2-setup-remote-backend` before continuing here.

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
  apply (the `new_workspace_url` output).
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
  creating a workspace under the wrong account is a real, costly mistake.
- **Confirm the AWS identity**: run `aws sts get-caller-identity` and show the user the account
  it resolves to, so they can confirm the new workspace's AWS resources (IAM role, S3 bucket)
  land in the right AWS account — the same account `4.3-configure-github-oidc` already
  confirmed and scoped CI's role to.

Once all of these are confirmed, write them into `databricks/infrastructure/terraform.tfvars`
(create it from `terraform.tfvars.example` if it doesn't exist yet) — this file is gitignored,
so it's the right place for these project-specific values. `databricks_account_profile` can
default to `ACCOUNT` unless the user wants a different profile name.

## Phase 2: Implement

```
bash .claude/skills/05-databricks-terraform-deployment/5.1-create-workspace/implement.sh
```

Idempotent — scaffolds `mws_provider.tf` (account-level provider + its 2 variables) and
`workspace.tf` (cross-account IAM role, root S3 bucket, `databricks_mws_*` resources, and their
variables/outputs) inside `databricks/infrastructure/`, and appends example values to
`terraform.tfvars.example`. Never overwrites a file that already exists — if either `.tf` file
is already there, it's left untouched and reused as-is. Only writes generic resource/variable
definitions, never the actual values gathered in Phase 1 (those go into `terraform.tfvars`,
handled directly per Phase 1, not by this script).

Uses the `databricks` provider's own `databricks_aws_assume_role_policy`,
`databricks_aws_crossaccount_policy`, and `databricks_aws_bucket_policy` data sources to
generate the IAM/S3 policies Databricks requires, rather than hand-maintained policy JSON —
these track Databricks' actual requirements instead of going stale.

## Phase 3: Deploy

Two ways to run this, now that `04-github-cicd` exists — pick based on how the user wants to
work, but either way state lands in the same S3 backend:

**A. Through the CI/CD pipeline (recommended, now that it exists)** — commit `mws_provider.tf`
and `workspace.tf` plus the non-secret parts of `terraform.tfvars.example`, push to a branch,
and open a PR. `terraform-plan.yml` runs automatically and posts the plan as a PR comment for
review; merging to `main` triggers `terraform-apply.yml`, which pauses for approval if the
`production` GitHub Environment has required reviewers configured, then applies. This is the
first real exercise of the pipeline `04-github-cicd` built.

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
- Warns (doesn't block) if the chosen root bucket name already exists and is reachable —
  S3 bucket names are globally unique, so a collision needs a different name.
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
plan-then-review-then-apply order), then prints the `new_workspace_url` /
`new_workspace_status` outputs. Workspace creation takes several minutes after `apply`
succeeds — check `new_workspace_status` or the Account Console until it reads `RUNNING`.

## Known IAM propagation delay

`databricks_mws_credentials` can fail on `apply` with `"Failed credential validation checks:
please use a valid cross account IAM role..."` even though the role/policy were just created
successfully — Databricks validates the role by actually assuming it, and IAM is eventually
consistent, so the assume-role can fail for a few seconds right after the policy is attached.
`workspace.tf` includes a `time_sleep.iam_propagation` resource (30s, depends on the role
policy) that `databricks_mws_credentials` depends on, to absorb this. If it still fails, the
role/policy are already in state — just re-run `deploy.sh plan` then `deploy.sh apply` again
(or re-run the pipeline), nothing needs to be recreated.

## Known: deployment_name usually isn't usable

`databricks_mws_workspaces` errors with `"Deployment name cannot be used until a deployment
name prefix is defined"` on any account that doesn't have a deployment name prefix configured
(an account-level setting only Databricks can set — most accounts don't have one, evidenced by
an existing workspace URL looking like `dbc-<random>.cloud.databricks.com` rather than a chosen
name). Because of this, `workspace.tf` deliberately does **not** set `deployment_name` on
`databricks_mws_workspaces` — Databricks auto-assigns the URL instead, read back via the
`new_workspace_url` output (`databricks_mws_workspaces.this.workspace_url`) after apply. The
`new_workspace_deployment_name` variable still exists and is used, but only to prefix the
account-level resource *names* (`credentials_name`, `storage_configuration_name`), not the URL.

## Known benign warning

`terraform plan`/`apply` prints a deprecation warning that `account_id` on the `databricks_mws_*`
resources "should be set as part of the Databricks Config, not in the resource." Ignore it —
in the provider version pinned by `versions.tf`, `databricks_mws_storage_configurations` and
`databricks_mws_workspaces` still error with "Missing required argument" if `account_id` is
removed from the resource, despite the warning. Confirmed by testing both ways; the resources
keep the explicit `account_id = var.databricks_account_id` deliberately.

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
- `implement.sh` never overwrites existing `.tf` files, matching `3.1-scaffold-infrastructure`'s
  convention.
- `new_workspace_root_bucket_force_destroy` defaults to `false` (AWS's own safe default) — only
  set `true` in `terraform.tfvars` if the user explicitly wants easy teardown of a disposable
  workspace, since `true` lets `terraform destroy` delete a non-empty bucket's data.
- Never runs this skill before `04-github-cicd`'s prerequisites are confirmed (see "Before
  starting") — running it earlier defeats the entire reason for that group's ordering: clean,
  S3-managed state from the first real `apply`.
