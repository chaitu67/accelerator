---
name: 4.2-setup-remote-backend
description: Migrate the databricks/infrastructure Terraform project from local state to a remote S3 backend (S3-native locking by default, or S3 + DynamoDB), so both a laptop and GitHub Actions runners read/write the same state safely. Use when 4.1-check-cicd-prerequisites reports local state still in use, or whenever the user asks to set up remote Terraform state / a shared backend before enabling CI/CD.
---

# Setup Remote Backend (databricks repo)

Second skill in the `04-github-cicd` group — see [../README.md](../README.md) for why this is
a prerequisite for CI/CD at all: a GitHub Actions runner has no access to a state file sitting
on someone's laptop, and two independent local states (one per machine) would drift and corrupt
each other's understanding of what's deployed.

Two phases, always in this order:

1. **Bootstrap** — create the S3 bucket (and, optionally, a DynamoDB lock table) that will hold
   state (`bootstrap.sh`).
2. **Migrate** — point `backend.tf` at them and run `terraform init -migrate-state`
   (`migrate.sh`).

## Locking: S3-native vs. DynamoDB

Terraform >= 1.10 supports native state locking directly in the S3 backend
(`use_lockfile = true`, a conditional-write lock file in the same bucket) — no DynamoDB table
needed. This is the **default** this skill uses. Ask the user only if it's not obvious which
they want:

- **S3-native locking** (default): one resource instead of two. Requires Terraform >= 1.10 for
  *every* consumer — this laptop and every GitHub Actions run. Check `terraform version`
  locally first; CI gets a recent version by default via `hashicorp/setup-terraform`.
- **DynamoDB lock table**: the older, more universally-compatible pattern (works on any
  Terraform >= 0.9). Pick this only if the user specifically wants to support an older pinned
  Terraform version somewhere in the pipeline.

Whichever is chosen, `versions.tf`'s `required_version` must actually reflect it — S3-native
locking needs `>= 1.10.0` (this skill raises it from `3.1-scaffold-infrastructure`'s
`>= 1.5.0` default; `3.2-check-prerequisites`'s CLI-version check reads the constraint from
`versions.tf` directly, so it stays correct automatically once this file is updated).

## Before starting

Confirm `3.2-check-prerequisites` passes (AWS auth, `terraform.tfvars` present) — this skill
only adds a backend on top of an already-working Terraform setup.

## Phase 1: Gather details

Ask the user (or default and confirm) rather than guessing, since a bucket name collision or
wrong region is annoying to unwind later:

- **State bucket name** — must be globally unique across all of S3. Suggest
  `<repo-name>-tfstate-<aws-account-id>` (unique without a random suffix, and legible as "the
  state bucket for this account") and confirm.
- **Locking method** — S3-native (default) or DynamoDB; see above. If DynamoDB, also gather a
  **lock table name** (suggest `<repo-name>-tfstate-lock`; no uniqueness constraint beyond this
  AWS account/region).
- **AWS region** — default to the existing `aws_region` in `terraform.tfvars`.

## Phase 2: Bootstrap

```
bash .claude/skills/04-github-cicd/4.2-setup-remote-backend/bootstrap.sh <bucket-name> <region> [lock-table-name]
```

Idempotent — creates the S3 bucket (versioning enabled, public access blocked, server-side
encryption on) only if it doesn't already exist. Omit `lock-table-name` for S3-native locking
(the default); pass it to also create a DynamoDB table (`LockID` string key, on-demand billing)
if the user chose that instead. Uses plain `aws` CLI calls, not Terraform — this is the one
piece of infrastructure that can't be managed by the Terraform project it will end up backing
(the project needs the bucket to exist before it can even initialize with this backend).

## Phase 3: Migrate

```
bash .claude/skills/04-github-cicd/4.2-setup-remote-backend/migrate.sh <bucket-name> <region> [lock-table-name]
```

- Rewrites `databricks/infrastructure/backend.tf` with an active `backend "s3"` block —
  `use_lockfile = true` if no lock table was given, `dynamodb_table = "<name>"` if one was.
  Refuses to run if the file already has a different active backend block — see Constraints.
- Runs `terraform init -migrate-state` inside `infrastructure/`, which prompts to confirm
  copying existing state into the new backend. **Show this prompt's output to the user** rather
  than silently answering it, since it's rewriting where the single source of truth for their
  deployed infrastructure lives.
- After a successful migrate, the pre-migration local `terraform.tfstate`/
  `terraform.tfstate.backup` files are left in place on disk (not deleted) — they're already
  gitignored and harmless to keep as a local fallback copy, but no longer authoritative.

## Constraints

- Never deletes an existing S3 bucket or DynamoDB table — only creates one if the given name
  doesn't already exist. If a bucket/table with that name exists but isn't usable as a
  Terraform backend (e.g. wrong region, versioning disabled), it stops and asks rather than
  reconfiguring someone else's resource.
- Never runs `terraform init -migrate-state` with `-force-copy` or otherwise skips the
  confirmation prompt — migrating state is exactly the kind of one-way-feeling operation that
  needs a human to see and confirm it.
- If `backend.tf` already has an active (uncommented) `backend "s3"` block when this skill
  runs, it stops and asks before overwriting it — don't silently repoint an already-configured
  backend at a different bucket/table.
- Bootstrap resources (bucket, table) are deliberately excluded from the `infrastructure/`
  Terraform project's own state — they hold that state, so they can't be created by it without
  a chicken-and-egg problem. If they ever need to be torn down, do it manually via the AWS
  CLI/Console, not `terraform destroy`.
