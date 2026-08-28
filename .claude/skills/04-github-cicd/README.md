# 04-github-cicd skills

Skills numbered `4.x` in this group set up GitHub Actions CI/CD for the Terraform project
inside the sibling `databricks` repo (cloned via
[01-clone-sibling-repo](../01-clone-sibling-repo/SKILL.md), scaffolded by
[03-terraform-setup](../03-terraform-setup/README.md)). Like the `3.x` group, these skills
write into the `databricks` repo, not `accelerator` itself.

## Why this runs before any real infrastructure is deployed

This group deliberately sits **between** project scaffolding and the first real deployment:
`03-terraform-setup` (project scaffold + prerequisite checks) → `04-github-cicd` (this group) →
[05-databricks-terraform-deployment](../05-databricks-terraform-deployment/README.md) (the
actual `terraform apply` that creates a workspace). The point of that ordering: by the time
anything real gets created, state is already living in the S3 backend this group sets up —
there's no local-state deployment to migrate later, no "oops, half our history is local and half
is remote." Clean state, managed from S3, from the very first `apply`.

A GitHub Actions runner also isn't the same environment as a laptop: it has no local Terraform
state file, no `~/.aws` profile, no `~/.databrickscfg` OAuth session. Each of those has to be
replaced with something a headless runner can use, which is why this is three prerequisite-setup
skills before there's an actual workflow file:

- No shared state to read from → a **remote S3 backend** every run reads from
  (`4.2-setup-remote-backend`).
- A human's `aws sso login` / `databricks auth login` browser session → **OIDC federation**, so
  GitHub issues a short-lived token the run trades for AWS credentials with no long-lived key
  stored anywhere (`4.3-configure-github-oidc`).
- Nothing to trigger on → the actual **workflow files** (`4.4-create-workflows`), which is what
  `05-databricks-terraform-deployment` merges through to do the first real `apply`.

## Skills in this group

- `4.1-check-cicd-prerequisites` — read-only audit of everything CI/CD depends on: GitHub CLI
  auth, remote Terraform backend, AWS OIDC provider/role, required repo secrets/variables,
  existing workflow files. Names the fix (usually the matching `4.x` skill below) for each gap.
- `4.2-setup-remote-backend` — migrates Terraform state from local to a remote S3 backend
  (S3-native locking by default, or S3 + DynamoDB), so both a laptop and a GitHub Actions
  runner read/write the same state safely.
- `4.3-configure-github-oidc` — creates the AWS IAM OIDC provider + role trusted only by this
  specific GitHub repo (no long-lived AWS access keys as secrets), sets up Databricks Workload
  Identity Federation (a service principal + federation policies — no Databricks secret either,
  the recommended path), and records every non-secret value (role ARN, region, Databricks host,
  client ID) as GitHub Actions repo variables. PAT/OAuth-M2M remain as fallbacks if federation
  isn't available (see the skill for the exact manual `gh secret set` step in that case).
- `4.4-create-workflows` — scaffolds `.github/workflows/terraform-plan.yml` (runs on pull
  requests touching `infrastructure/`: fmt check, validate, plan, posted as a PR comment) and
  `terraform-apply.yml` (runs on merge to `main`, gated on a required-reviewer GitHub
  Environment before `terraform apply`).
- `4.5-open-terraform-pr` — commits uncommitted `infrastructure/` (or other `databricks` repo)
  changes to a branch, pushes it, and opens a PR against `main`, so `terraform-plan.yml` runs and
  the change goes through review instead of a direct push to `main`. The ongoing, repeatable way
  changes actually flow through the pipeline the rest of this group builds once.

## Order

Run in order: `4.1` to see what's missing → whichever of `4.2`/`4.3` it points at → `4.4` last,
since the workflow files created by `4.4` assume the backend and OIDC role already exist. Re-run
`4.1` after each step to confirm the gap closed. Once `4.1` is all green, move on to
`05-databricks-terraform-deployment` — its `5.1-create-workspace` is the first skill that
actually creates real infrastructure. From then on, `4.5-open-terraform-pr` is how any
Terraform change (from `5.1` or later work) actually gets submitted through the pipeline this
group built, rather than a direct local `terraform apply` or a direct push to `main`.

## Convention

- A new skill in this group gets the next `4.N` number and its own subdirectory:
  `04-github-cicd/4.N-<name>/`.
- If a `4.N` skill needs its own finer-grained steps, they nest one level deeper as
  `4.N.M-<name>/`, same rule as the `3.x` group.
- Each still needs its own `SKILL.md` per the usual skill format — this README is an index for
  the group, not a skill itself.

## Constraints (apply to the whole group)

- Targets **GitHub Actions** specifically (the `databricks` repo's origin remote is a GitHub
  URL) — not GitLab CI, CircleCI, or another CI provider.
- Everything here operates on the `databricks/infrastructure` Terraform project only. CI for
  application code (notebooks, jobs, Python packages) elsewhere in `databricks` is out of
  scope for this group.
- No skill in this group ever types, echoes, or stores a secret value (AWS keys, Databricks
  tokens/client secrets) itself — OIDC/Workload Identity Federation removes the need for a
  long-lived key or secret on either side entirely; if the fallback PAT/OAuth-M2M path is used
  instead, that one remaining secret is always a manual `gh secret set` run by the user in their
  own terminal, matching how `3.2.1`/`3.2.2` handle credentials.
- No skill in this group runs `terraform apply` directly — that only ever happens inside the
  GitHub Actions workflow itself, after its own plan/review gate.
- No skill in this group pushes directly to `main` or merges a PR — `4.5-open-terraform-pr`
  stops at opening the PR; review and merge are always a human decision.
