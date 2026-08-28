---
name: 3.1-scaffold-infrastructure
description: Create (or reuse, if present) an infrastructure/ Terraform project inside the sibling databricks repo, scaffolded for deploying Databricks-related infrastructure on AWS. Use whenever the user asks to set up, initialize, or scaffold Databricks infrastructure-as-code, or before adding Terraform resources for Databricks in the databricks repo.
---

# Scaffold Infrastructure (databricks repo)

First skill in the `03-terraform-setup` group — see [../README.md](../README.md) for the group
convention. Skills in this group implement things directly inside the sibling `databricks`
repo rather than in `accelerator` itself. This one creates the `infrastructure/` Terraform
project that later `3.x` skills add resources to.

## What it does

- Locates the `databricks` repo as a sibling of `accelerator` (same parent directory).
- Creates `databricks/infrastructure/` as a Terraform project scaffold — provider config,
  variables, empty main/outputs — **only if it doesn't already exist**.
- If `infrastructure/` already exists, it is left completely untouched and reused as-is.
  This skill never overwrites or regenerates an existing scaffold.

## Running it

```
bash .claude/skills/03-terraform-setup/3.1-scaffold-infrastructure/init.sh
```

Resolves the accelerator repo root itself (via `git rev-parse --show-toplevel`), so it works
regardless of the caller's cwd. Requires the `databricks` sibling repo to already be cloned —
the script errors out with instructions to run `01-clone-sibling-repo` first if it's missing.

## Scaffold contents

- `versions.tf` — Terraform version constraint plus required providers:
  `databricks/databricks` and `hashicorp/aws`.
- `providers.tf` — AWS and Databricks provider blocks, configured from variables.
- `variables.tf` — `aws_region`, `aws_profile`, `databricks_profile` (default `"DEFAULT"` —
  the OAuth profile `3.2.2-authenticate-databricks` sets up), plus optional
  `databricks_host`/`databricks_token` (both default `null`) to override with PAT auth instead.
- `main.tf` / `outputs.tf` — empty, for later `3.x` skills to add resources/outputs to.
- `backend.tf` — commented-out S3 remote backend example. State is **local for now**;
  when ready to move to a remote backend, fill in the values and run
  `terraform init -migrate-state`.
- `terraform.tfvars.example` — example non-secret values to copy to `terraform.tfvars`.
- `.gitignore` — standard Terraform ignores (state files, `.terraform/`, `terraform.tfvars`).

## Constraints

- Never overwrites, deletes, or regenerates an existing `infrastructure/` directory — if
  it's already there, this skill is a no-op that just reports the existing path.
- Never runs `terraform init`/`plan`/`apply` itself — scaffolding only. Applying
  infrastructure is a separate, deliberate action the user takes.
- Targets AWS specifically (the project already provisions boto3 and the AWS CLI via
  `02-setup-local-env`) — not cloud-agnostic.
- Never commits secrets — `databricks_token` has no default and `terraform.tfvars` is
  gitignored.
