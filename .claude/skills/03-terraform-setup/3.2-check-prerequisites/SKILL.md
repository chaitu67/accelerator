---
name: 3.2-check-prerequisites
description: Audit everything required to run terraform init/plan/apply against the databricks/infrastructure project - sibling repo present, infrastructure/ scaffolded, terraform/aws/databricks CLIs installed, AWS credentials valid, and Databricks host/token available. Read-only, fixes nothing itself. Use whenever the user asks what's needed to deploy Databricks infrastructure via Terraform, or before running terraform commands, to confirm the environment is actually ready.
---

# Check Prerequisites (databricks repo)

Second skill in the `03-terraform-setup` group — see [../README.md](../README.md) for the
group convention. Where `3.1-scaffold-infrastructure` creates the Terraform project, this skill
answers "am I actually ready to run it?" — a single read-only pass over every prerequisite,
each with the exact fix (usually another skill) when it's missing.

## What it checks

1. **Sibling `databricks` repo** cloned next to `accelerator`.
2. **`infrastructure/` Terraform scaffold** exists inside it.
3. **CLI tools** on `PATH`: `terraform`, `aws`, `databricks` — plus that the installed
   Terraform version satisfies the `>= 1.5.0` constraint in `versions.tf`.
4. **AWS credentials** — `aws sts get-caller-identity` succeeds; reports the authenticated
   account/ARN.
5. **Databricks credentials** — `databricks current-user me` succeeds (falls back to checking
   for host/token material if the CLI itself isn't installed yet).
6. **`terraform.tfvars`** present (copied from `terraform.tfvars.example` and filled in).

## Running it

```
bash .claude/skills/03-terraform-setup/3.2-check-prerequisites/check.sh
```

Resolves the accelerator repo root itself (via `git rev-parse --show-toplevel`), so it works
regardless of the caller's cwd. Prints `[OK]` / `[WARN]` / `[MISSING]` per item and exits
non-zero if anything required is missing.

## When a check fails

Each `[MISSING]` line names the fix directly:

- Repo missing → run `01-clone-sibling-repo`.
- Scaffold missing → run `3.1-scaffold-infrastructure`.
- CLI tool missing → run `02-setup-local-env`.
- AWS not authenticated → run
  [3.2.1-authenticate-aws](3.2.1-authenticate-aws/SKILL.md).
- Databricks not authenticated → run
  [3.2.2-authenticate-databricks](3.2.2-authenticate-databricks/SKILL.md).

For the two authentication checks specifically: if step 4 or 5 above comes back `[MISSING]`,
run the corresponding `3.2.1`/`3.2.2` sub-skill immediately rather than just reporting the gap
— they walk through what can be done unattended (browser-based SSO/OAuth login) and hand back
the exact manual command for anything that needs a human typing a secret. Once a sub-skill
finishes, re-run this check (`check.sh`) to confirm the gap is closed before moving on to
`terraform init`/`plan`/`apply`.

## Sub-skills

- [3.2.1-authenticate-aws](3.2.1-authenticate-aws/SKILL.md) — gets
  `aws sts get-caller-identity` passing.
- [3.2.2-authenticate-databricks](3.2.2-authenticate-databricks/SKILL.md) — gets
  `databricks current-user me` passing.

## Constraints

- Read-only: never installs, configures, or writes anything. It only reports gaps and names
  the fix (or, for authentication, delegates to `3.2.1`/`3.2.2`).
- Never prints or logs a Databricks token or AWS secret — only confirms authentication and, for
  AWS, the resulting identity (account/ARN), which isn't secret.
- Credential setup that needs typed secrets (`aws configure`, `databricks configure --token`,
  generating a Databricks PAT) is always left to the user to run themselves in their own
  terminal — see the sub-skills' own constraints.
