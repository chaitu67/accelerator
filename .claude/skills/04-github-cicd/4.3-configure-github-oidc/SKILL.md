---
name: 4.3-configure-github-oidc
description: Create an AWS IAM OIDC provider + role trusted only by the databricks GitHub repo, and set up Databricks CI auth -- preferably Workload Identity Federation (a Databricks service principal + federation policies, no secret at all), or PAT/OAuth-M2M as fallbacks. Records every non-secret value as a GitHub Actions repo variable. Use when 4.1-check-cicd-prerequisites reports the OIDC provider/role or repo variables/secrets missing, or whenever the user asks to set up AWS or Databricks auth for GitHub Actions CI/CD.
---

# Configure GitHub OIDC (databricks repo)

Third skill in the `04-github-cicd` group — see [../README.md](../README.md). Where `4.2`
gives CI a shared place to read/write state, this skill gives it a way to authenticate as AWS
and Databricks without a human's browser session or a long-lived secret sitting in the repo.

Four phases, always in this order:

1. **Gather details** — a conversation, not a script (see below).
2. **AWS OIDC + role** — create the trust relationship (`setup-oidc.sh`).
3. **Databricks Workload Identity Federation** (recommended) — service principal + federation
   policies, no secret (`setup-databricks-federation.sh`).
4. **Repo variables + secret handoff** — record the remaining non-secret values, and print the
   manual step for the one actual secret *only if* Phase 1 chose PAT or OAuth-M2M instead of
   federation (`setup-secrets.sh`).

## Why OIDC/federation instead of long-lived keys or tokens as GitHub secrets

A static AWS access key or Databricks PAT pasted into a GitHub secret is a long-lived credential
that works forever (or until manually rotated) from anywhere it leaks. OIDC/workload identity
federation instead lets GitHub issue a short-lived, workflow-run-scoped token that AWS/Databricks
exchange for temporary credentials — there is no secret to leak, rotate, or accidentally log.
This is the recommended pattern on both sides:

- AWS: see `aws-actions/configure-aws-credentials`'s own docs for the trust model `setup-oidc.sh`
  sets up.
- Databricks: "Databricks strongly recommends using Workload Identity Federation to authenticate
  to Databricks from automated workloads, over alternatives such as OAuth client secrets or
  Personal Access Tokens, whenever possible" — straight from `databricks account
  service-principal-federation-policy --help`. `setup-databricks-federation.sh` implements
  exactly this.

## Before starting

Confirm `3.2-check-prerequisites` and `4.1-check-cicd-prerequisites` pass for everything except
the items this skill fixes (AWS auth locally, `gh` installed). Databricks federation additionally
needs **account-level** Databricks auth (the same `ACCOUNT` profile
`05-databricks-terraform-deployment`'s `deploy.sh` sets up) — federation policies are
account-admin territory, not workspace-level.

## Phase 1: Gather details

- **AWS identity to create resources under**: run `aws sts get-caller-identity` and show the
  user the account — the OIDC provider and IAM role are created in this AWS account, and it's
  the same account `05-databricks-terraform-deployment`'s `5.1-create-workspace` will later
  deploy real infrastructure into via this pipeline. Confirm it's the right one — getting this
  wrong here means CI ends up authorized against the wrong AWS account before anything real has
  even been deployed.
- **GitHub repo slug** (`owner/repo`): derive from `databricks`'s `origin` remote; confirm with
  the user rather than assuming a fork/mirror isn't in play.
- **GitHub Environment name for apply**: default `production` (matching `4.4-create-workflows`'s
  `terraform-apply.yml`). This becomes part of the Databricks federation subject for the apply
  workflow, so it must match exactly what `4.4` scaffolds and what's configured under
  Settings → Environments on GitHub.
- **Databricks workspace URL** (`databricks_host`, e.g. `https://<workspace>.cloud.databricks.com`)
  — since `terraform.tfvars` is gitignored (per `3.1-scaffold-infrastructure`), CI has no local
  file to read it from; it's recorded as a **repo variable** in Phase 4 instead. Not a secret —
  a workspace URL alone grants no access. If the user already has a workspace, `~/.databrickscfg`
  usually has it under the profile they use locally.
- **Databricks CI credential type** — ask which the user wants:
  - **Federated / Workload Identity (recommended)**: no secret at all. Requires an account
    admin (Phase 3 checks/uses the local `ACCOUNT` profile) and `databricks/infrastructure`'s
    `providers.tf`/`variables.tf` to support `auth_type = "github-oidc"` +
    `client_id` — already wired up as of this skill's current version (see
    `databricks_auth_type`/`databricks_client_id` in `variables.tf`; if a fresh `databricks` repo
    doesn't have these yet, add them the same way before running Phase 3).
  - **Personal access token (PAT)**: simplest, but tied to the human who created it. Generate one
    in the workspace (Settings → Developer → Access tokens). Fine for a workshop/test setup.
  - **Service principal + OAuth client secret (M2M)**: not tied to a human, but the secret still
    needs periodic rotation — federation is strictly better where account-admin access is
    available.
  - Default to **federated** unless the user has a specific reason to prefer PAT/M2M (e.g. no
    account-admin access available to whoever is running this skill).

## Phase 2: AWS OIDC + role

```
bash .claude/skills/04-github-cicd/4.3-configure-github-oidc/setup-oidc.sh <owner/repo> [apply-environment-name]
```

Idempotent:

- Creates the `token.actions.githubusercontent.com` OIDC provider in this AWS account if it
  doesn't already exist (reused across every repo that wants GitHub Actions OIDC in this
  account — not recreated per-repo).
- Creates IAM role `github-actions-<repo-name>-terraform` if it doesn't exist, with a trust
  policy scoped to exactly the two subjects this repo's workflows ever present —
  `repo:<owner>/<repo>:pull_request` (for `terraform-plan.yml`) and
  `repo:<owner>/<repo>:environment:<apply-environment-name>` (for `terraform-apply.yml`'s
  job-level `environment:`, default `production`) — not a `repo:<owner>/<repo>:*` wildcard. This
  now matches the Databricks federation side's precision (see Phase 3) rather than being the
  broader of the two; confirmed empirically via CloudTrail against every historical
  `AssumeRoleWithWebIdentity` call for this repo before narrowing it. If a workflow ever needs a
  genuinely new trigger context (a new environment name, `workflow_dispatch`, etc.), re-run this
  script with the new environment name, or extend the subject list directly — it will otherwise
  fail auth the same way a typo'd repo slug would.
- Attaches an inline policy granting the permissions the `infrastructure/` project's resources
  need: read/write on the S3 state bucket (plus the DynamoDB lock table, only if `4.2` was
  configured with one instead of S3-native locking), and the IAM/S3-adjacent AWS actions the
  `05-databricks-terraform-deployment` skill's `workspace.tf` uses. Re-run after adding new
  resource types to `infrastructure/` that need additional AWS permissions — the script only
  ever adds statements, never removes ones a prior run added, so a hand-added policy tweak
  survives a re-run.

## Phase 3: Databricks Workload Identity Federation (if chosen in Phase 1)

```
bash .claude/skills/04-github-cicd/4.3-configure-github-oidc/setup-databricks-federation.sh <owner/repo> <databricks-host> [environment-name] [account-profile]
```

Idempotent. Requires the local `ACCOUNT` Databricks CLI profile to already be authenticated (an
account admin operation — the script checks and tells you the exact `databricks auth login`
command if not, same as `5.1-create-workspace`'s `deploy.sh` does for workspace creation):

1. Creates an account-level service principal named `github-actions-<repo-name>-terraform` if it
   doesn't already exist (matched by display name).
2. Assigns it to the target workspace with `USER` permission (the minimal grant — if the
   Terraform-managed resources need more, e.g. catalog or cluster-policy access, grant that
   manually in the workspace; this script deliberately doesn't guess a broader scope).
3. Creates **two** federation policies on that service principal (skipped if a matching one
   already exists, checked by subject):
   - `repo:<owner>/<repo>:pull_request` — for `terraform-plan.yml`, which runs on PRs outside
     any GitHub Environment.
   - `repo:<owner>/<repo>:environment:<environment-name>` — for `terraform-apply.yml`, which
     runs inside the `production` (or chosen) GitHub Environment. Both policies use issuer
     `https://token.actions.githubusercontent.com` and audience `https://github.com/<owner>`
     (GitHub's default OIDC token audience — matches what a workflow's ID token actually
     presents without any extra configuration).
4. Sets `DATABRICKS_CLIENT_ID` as a GitHub repo variable (the service principal's application
   ID — **not secret**, it grants no access without a matching federation policy).

No `gh secret set` needed for Databricks at all when this path is used — skip straight to
`4.4-create-workflows` after Phase 4 sets the remaining AWS/host variables.

## Phase 4: Repo variables + secret handoff

```
bash .claude/skills/04-github-cicd/4.3-configure-github-oidc/setup-secrets.sh <owner/repo> <databricks-host> [pat|service-principal|federated]
```

- Sets non-secret **repo variables** via `gh variable set`: `AWS_ROLE_TO_ASSUME` (the role ARN
  from Phase 2), `AWS_REGION`, and `DATABRICKS_HOST` (the workspace URL from Phase 1). None of
  these are secrets, so they're plain variables, visible in the Actions UI.
- If `federated` was chosen, this step is complete — Phase 3 already set `DATABRICKS_CLIENT_ID`
  and there's no secret to hand off.
- If `pat` or `service-principal` was chosen instead, **prints the exact command** for the user
  to run in their own terminal — this script never asks for, receives, or transmits the actual
  secret value (see the script's output for the exact `gh variable set`/`gh secret set` lines).

After Phase 3/4, re-run `4.1-check-cicd-prerequisites` to confirm everything is now present
(secret/variable names only — values are never checked or displayed) before moving on to
`4.4-create-workflows`.

## Constraints

- Never creates or handles a static AWS access key/secret — OIDC is the only AWS auth path this
  skill sets up.
- Never asks the user to paste a Databricks token or OAuth secret into the conversation —
  always a `gh secret set` command run directly in their own terminal, matching
  `3.2.1`/`3.2.2`'s handling of AWS/Databricks credentials. The federated path avoids this
  entirely by not having a secret in the first place.
- The AWS trust policy is scoped to the specific `owner/repo` (never an entire GitHub org or
  `repo:*` wildcard). The Databricks federation policies are scoped even tighter — to the exact
  `pull_request` or `environment:<name>` subject, not `repo:<owner>/<repo>:*`.
- Never deletes or narrows an existing OIDC provider, IAM role, service principal, or federation
  policy — every script here only creates what's missing and adds policy statements, matching
  the "never overwrite" convention used throughout `03-terraform-setup`.
- The AWS inline policy grants only what `infrastructure/`'s current resources need, not
  `AdministratorAccess` — CI running unattended on every PR/push is a materially different risk
  profile than the one-time interactive `3.2.1-authenticate-aws` setup, where a broad policy is
  an acceptable workshop shortcut. The Databricks workspace assignment is similarly minimal
  (`USER`, not `ADMIN`) by default.
