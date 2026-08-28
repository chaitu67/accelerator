---
name: 4.4-create-workflows
description: Scaffold the GitHub Actions workflow files for databricks/infrastructure - terraform-plan.yml (fmt/validate/plan on pull requests, posted as a PR comment) and terraform-apply.yml (apply on merge to main, gated on a required-reviewer GitHub Environment). Use when 4.1-check-cicd-prerequisites reports workflow files missing, or whenever the user asks to create/scaffold the actual CI/CD pipeline files for Databricks Terraform, after the remote backend and OIDC role already exist.
---

# Create Workflows (databricks repo)

Fourth and last skill in the `04-github-cicd` group — see [../README.md](../README.md). Where
`4.2`/`4.3` set up what the pipeline runs *against* (remote state, an assumable AWS role), this
skill writes the pipeline itself.

## Before starting

Run (or confirm already passing) `4.1-check-cicd-prerequisites` — these workflow files assume
`AWS_ROLE_TO_ASSUME`/`AWS_REGION` repo variables and a Databricks credential secret already
exist (from `4.3-configure-github-oidc`). A workflow referencing a variable/secret that doesn't
exist yet will fail on its first run, not error out at scaffold time — check first rather than
finding out from a broken Actions run.

## Gather one detail first

**GitHub Environment for apply**: ask whether the user already has (or wants this skill to
assume) a GitHub Environment named `production` with required reviewers configured
(Settings → Environments in the databricks repo on GitHub — this is a repo-settings change made
in the GitHub UI, not something `gh`/Terraform manages here). If they don't have one yet, tell
them to create it before merging anything that would trigger `terraform-apply.yml`, since
without required reviewers configured, the environment gate is a no-op and apply runs
unattended on every merge to `main`.

## Running it

```
bash .claude/skills/04-github-cicd/4.4-create-workflows/scaffold.sh
```

Idempotent — writes `.github/workflows/terraform-plan.yml` and
`.github/workflows/terraform-apply.yml` into the `databricks` repo only if they don't already
exist; an existing file with either name is left untouched and reused as-is (same convention as
`3.1-scaffold-infrastructure`).

## What the workflows do

**`terraform-plan.yml`** — triggers on `pull_request` (any branch) touching
`infrastructure/**`:
1. Checks out the repo, configures AWS credentials via OIDC
   (`aws-actions/configure-aws-credentials`, assuming `AWS_ROLE_TO_ASSUME`) — no AWS access key
   anywhere in the workflow.
2. Sets `TF_VAR_databricks_auth_type=github-oidc` and `TF_VAR_databricks_client_id` (from the
   `DATABRICKS_CLIENT_ID` repo variable) so the `databricks` Terraform provider authenticates via
   Workload Identity Federation — no Databricks secret in this workflow either. If
   `4.3-configure-github-oidc` was run with the PAT/OAuth-M2M path instead, swap this step for
   the matching `TF_VAR_databricks_token` (or `_client_secret`) env var read from a repo secret.
3. Runs `terraform fmt -check`, `terraform init`, `terraform validate`, `terraform plan`.
4. Posts the plan output as a comment on the PR (via `actions/github-script`), so reviewers see
   exactly what would change without needing repo/AWS access themselves.
5. Never runs `apply` — this workflow is read-only against real infrastructure.

**`terraform-apply.yml`** — triggers on `push` to `main` touching `infrastructure/**`:
1. Same checkout + OIDC auth + Databricks credential setup as the plan workflow.
2. Runs inside the `production` GitHub Environment — if that environment has required
   reviewers configured, the job pauses for manual approval before proceeding (this is what
   actually gates `apply`; the workflow YAML alone can't enforce approval without the
   Environment's own protection rules).
3. Runs `terraform init`, `terraform plan -out=tfplan`, `terraform apply tfplan` — plan-then-
   apply-the-saved-plan, same discipline `05-databricks-terraform-deployment`'s
   `5.1-create-workspace` skill uses for its own local `deploy.sh`, so what gets approved is
   exactly what gets applied.

## Gotcha: every required Terraform variable needs a matching TF_VAR_ line here

CI has **no access** to the gitignored `terraform.tfvars` that `5.1-create-workspace`'s Phase 1
writes locally (deliberately — that's the whole point of gitignoring it). Any variable in
`infrastructure/` with no default (e.g. `databricks_account_id`, `new_workspace_name`,
`new_workspace_deployment_name`, `new_workspace_root_bucket` from `workspace.tf`/
`mws_provider.tf`) will make `terraform plan`/`apply` fail in CI with "No value for required
variable" even though the AWS/Databricks auth steps succeed — this is a distinct failure mode
from an auth problem, and it's easy to misdiagnose as one. Confirmed live: exactly this happened
when validating this skill against a real deployment.

Fix, for each such variable (assuming its value isn't secret — check the corresponding
`terraform.tfvars` comment/description in `variables.tf` first):
1. `gh variable set <NAME> --repo <owner/repo> --body "<value>"` (a plain repo variable, not a
   secret — matches how `4.3` handles `DATABRICKS_HOST` etc.).
2. Add `TF_VAR_<name>: ${{ vars.<NAME> }}` to the `env:` block of **both**
   `terraform-plan.yml`'s and `terraform-apply.yml`'s `Terraform plan` step — missing either one
   means that workflow fails while the other works, which is its own confusing symptom.

If a value genuinely is secret, use `gh secret set` and `${{ secrets.<NAME> }}` instead, same
pattern as the PAT/OAuth-M2M fallback paths in `4.3`.

## Constraints

- Never overwrites an existing `terraform-plan.yml`/`terraform-apply.yml` — if the user wants
  to change one, edit it directly rather than re-running this skill.
- `terraform-apply.yml` always targets the `production` GitHub Environment by name — if the
  user wants a different name, tell them to rename it consistently in both the workflow file
  and their GitHub Environment settings rather than silently picking a different one.
- Neither workflow ever hardcodes an AWS access key, Databricks token, or any other secret
  value — every credential comes from the OIDC role or a repo secret referenced by name.
- `terraform-apply.yml` never runs `terraform apply` without a preceding `plan -out=tfplan` in
  the same job — matching the plan-before-apply discipline used everywhere else in this
  project.
