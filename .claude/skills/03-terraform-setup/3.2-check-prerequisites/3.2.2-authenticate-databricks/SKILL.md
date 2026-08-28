---
name: 3.2.2-authenticate-databricks
description: Authenticate the Databricks CLI/Terraform provider against the target workspace so 'databricks current-user me' succeeds. Use when 3.2-check-prerequisites reports Databricks credentials missing/invalid, or whenever the user asks to log in to / authenticate with Databricks for this project.
---

# Authenticate Databricks

Sub-skill of [../SKILL.md](../SKILL.md) (`3.2-check-prerequisites`), covering step 5 of that
check: getting the Databricks CLI (and by extension the Terraform `databricks` provider)
authenticated against the target workspace.

## Running it

```
bash .claude/skills/03-terraform-setup/3.2-check-prerequisites/3.2.2-authenticate-databricks/authenticate.sh
```

Resolves the accelerator repo root itself, so it works regardless of the caller's cwd. Resolves
the workspace host in this order: `$DATABRICKS_HOST`, `$TF_VAR_databricks_host`,
`databricks_host` in `databricks/infrastructure/terraform.tfvars`.

## What it does

1. Checks whether the CLI is already authenticated (`databricks current-user me`) — if so,
   reports the user and exits, nothing else to do.
2. If a workspace host is known, attempts `databricks auth login --host <host>`, which opens a
   browser for OAuth (U2M) login. Safe to run directly — no token ever passes through this
   script or Claude.
3. If no host is known yet, or the OAuth login fails/isn't supported for that workspace, it
   cannot proceed unattended and prints the fallback: generate a personal access token in the
   Databricks workspace UI (User Settings > Developer > Access tokens), then either
   `databricks configure --host <host> --token` (typed by the user in their own terminal) or
   `export TF_VAR_databricks_token=<token>`.

## After the user runs a manual step

Re-run this skill (or `3.2-check-prerequisites`) to confirm `databricks current-user me` now
succeeds before moving on.

## Constraints

- Never asks the user to paste a personal access token into chat, and never types one into a
  command itself — token entry only ever happens in the user's own terminal.
- Only ever runs `databricks auth login` (browser-mediated OAuth) and read-only identity
  checks. Generating or configuring a PAT is always left for the user to do themselves.
