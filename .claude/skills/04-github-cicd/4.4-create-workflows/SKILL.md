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

## Convention: non-secret, per-deployment config goes in committed `*.auto.tfvars`, not TF_VAR_/repo variables

CI has **no access** to the gitignored `terraform.tfvars` that Phase-1-style conversational
steps write locally (deliberately — that's the whole point of gitignoring it). An earlier
version of this project handled that by adding a `gh variable set` + a `TF_VAR_<name>: ${{
vars.<NAME> }}` line per required variable (e.g. `databricks_account_id`, workspace
name/region/bucket) — this worked, but meant every new variable, and every new *instance* of
data using that variable (e.g. a second Databricks workspace), needed a matching edit to both
workflow files plus a manual `gh variable set`. That's exactly the two real CI failures hit
during this project's first workspace creation (a forgotten `TF_VAR_` line, and a value that had
a default so it silently used the wrong one instead of erroring).

**The fix, and the standing convention now:** if the data isn't secret (names, regions, bucket
names, tiers, account IDs — anything already visible in a `terraform plan` or PR comment isn't
secret), put it in a **committed** `*.auto.tfvars` or `*.auto.tfvars.json` file inside
`infrastructure/` instead of a GitHub repo variable. Terraform auto-loads any `*.auto.tfvars*`
file from its working directory automatically — locally **and** in CI, since CI checks out the
whole repo — with zero `TF_VAR_*`, zero `gh variable set`, and zero workflow YAML edits, no
matter how many such variables or deployment instances (e.g. workspaces) are added later. See
`05-databricks-terraform-deployment/5.1-create-workspace`'s `account.auto.tfvars` /
`workspaces.auto.tfvars` for the pattern in practice.

Reserve actual `TF_VAR_*`/repo-variable wiring in these workflow files for genuinely
cross-cutting **CI identity plumbing** — `databricks_host`, `databricks_auth_type`,
`databricks_client_id` — values that describe *how CI authenticates* and legitimately differ
between a local run and a CI run. That set rarely changes and is already correctly wired in the
scaffolded workflows; don't add to it for ordinary deployment data.

If a value genuinely is secret (a token, a client secret), use `gh secret set` and `${{
secrets.<NAME> }}` — never commit it, same pattern as the PAT/OAuth-M2M fallback paths in `4.3`.

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
