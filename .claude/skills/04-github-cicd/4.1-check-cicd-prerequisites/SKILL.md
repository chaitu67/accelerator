---
name: 4.1-check-cicd-prerequisites
description: Audit everything required for GitHub Actions CI/CD to run terraform plan/apply against the databricks/infrastructure project - gh CLI authenticated, remote Terraform backend (S3 + DynamoDB), AWS OIDC provider/role for GitHub Actions, required repo secrets/variables, existing workflow files. Read-only, fixes nothing itself. Use whenever the user asks what's needed to set up CI/CD for Databricks Terraform, or before creating GitHub Actions workflows, to confirm the environment is actually ready.
---

# Check CI/CD Prerequisites (databricks repo)

First skill in the `04-github-cicd` group — see [../README.md](../README.md) for the group
convention and why each prerequisite exists. Mirrors `3.2-check-prerequisites`'s role in the
`03-terraform-setup` group: a single read-only pass over everything CI/CD needs, each with
the exact fix when it's missing.

## What it checks

1. **`03-terraform-setup` prerequisites** — delegates to `3.2-check-prerequisites`'s
   `check.sh` first. CI/CD can't be ready if the base Terraform setup isn't.
2. **GitHub remote** — `databricks/infrastructure`'s repo has a GitHub `origin` remote (not
   another host); reports the `owner/repo` this group's skills will target.
3. **`gh` CLI** — installed and authenticated (`gh auth status`).
4. **Remote Terraform backend** — `backend.tf` has an active (uncommented) `backend "s3"` block,
   not the local-state default `3.1-scaffold-infrastructure` leaves in place.
5. **AWS OIDC provider + role** — an IAM OIDC identity provider for
   `token.actions.githubusercontent.com` exists in the AWS account, and an IAM role trusting
   this specific `owner/repo` exists.
6. **GitHub repo variables/secrets** — `AWS_ROLE_TO_ASSUME` and `AWS_REGION` set as repo
   variables; a Databricks credential (`DATABRICKS_TOKEN` or
   `DATABRICKS_CLIENT_ID`/`DATABRICKS_CLIENT_SECRET`) set as repo secret(s).
7. **Workflow files** — `.github/workflows/terraform-plan.yml` and
   `.github/workflows/terraform-apply.yml` present in the `databricks` repo.

## Running it

```
bash .claude/skills/04-github-cicd/4.1-check-cicd-prerequisites/check.sh
```

Resolves the accelerator repo root itself (via `git rev-parse --show-toplevel`), so it works
regardless of the caller's cwd. Prints `[OK]` / `[WARN]` / `[MISSING]` per item and exits
non-zero if anything required is missing.

## When a check fails

Each `[MISSING]` line names the fix directly:

- Base Terraform prerequisites missing → run `3.2-check-prerequisites` (it names the specific
  sub-fix).
- `gh` not installed → run `02-setup-local-env`.
- `gh` not authenticated → `gh auth login` (interactive; the check prints this, doesn't run it).
- Local backend still in use → run `4.2-setup-remote-backend`.
- OIDC provider/role missing → run `4.3-configure-github-oidc`.
- Repo variables/secrets missing → run `4.3-configure-github-oidc` (variables) — it also prints
  the exact `gh secret set` command for the Databricks credential, since that step needs a
  human to supply the actual secret value.
- Workflow files missing → run `4.4-create-workflows`.

Re-run this check after each fix to confirm the gap is closed before moving on.

## Constraints

- Read-only: never installs, configures, writes, or authenticates anything. It only reports
  gaps and names the fix.
- Never prints or logs the contents of a GitHub secret or AWS credential — only confirms a
  secret/variable's *name* is set, never its value (`gh secret list` doesn't expose values by
  design; this script relies on that rather than trying to read them).
