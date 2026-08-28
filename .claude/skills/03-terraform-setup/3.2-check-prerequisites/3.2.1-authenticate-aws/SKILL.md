---
name: 3.2.1-authenticate-aws
description: Authenticate the AWS CLI so 'aws sts get-caller-identity' succeeds for the profile the databricks/infrastructure Terraform project uses. Use when 3.2-check-prerequisites reports AWS credentials missing/invalid, or whenever the user asks to log in to / authenticate with AWS for this project.
---

# Authenticate AWS

Sub-skill of [../SKILL.md](../SKILL.md) (`3.2-check-prerequisites`), covering step 4 of that
check: getting `aws sts get-caller-identity` to succeed for the profile this deployment uses.

## Running it

```
bash .claude/skills/03-terraform-setup/3.2-check-prerequisites/3.2.1-authenticate-aws/authenticate.sh
```

Resolves the accelerator repo root itself, so it works regardless of the caller's cwd. Picks
the profile to check in this order: `$AWS_PROFILE`, `aws_profile` in
`databricks/infrastructure/terraform.tfvars`, else `default`.

## What it does

1. Checks whether the profile is already authenticated (`aws sts get-caller-identity`) — if
   so, reports the identity and exits, nothing else to do.
2. If the profile is configured for SSO (an `sso_start_url`/`sso_session` entry in
   `~/.aws/config`), runs `aws sso login --profile <profile>`, which opens a browser for the
   user to complete login. This is safe to run directly — the browser step never exposes a
   secret to this script or to Claude.
3. Otherwise, it cannot proceed unattended: `aws configure` and `aws configure sso` are
   interactive wizards (typed access keys, or an SSO account/role picker) that need a real
   terminal. It prints **both** paths below — SSO and static keys — with the pre-setup each
   needs, and stops.

## Choosing SSO vs static access keys

Whether SSO even applies depends on the user's AWS setup, and the script can't detect this
before authentication exists (chicken-and-egg) — it prints both paths every time it falls
through to the manual step. When relaying this to the user, don't just dump both options
uncritically:

- **SSO (IAM Identity Center)** only applies if the account is part of an **AWS Organization**
  with Identity Center already enabled, and the user has already been granted access to an
  account/permission set there — that's admin-side setup, not something a standalone account
  has by default. If the user says they're on a standalone account / not using AWS
  Organizations, SSO doesn't apply — go straight to static keys instead of asking them to try
  `aws configure sso` first.
- **Static IAM access keys** is the standard, simpler path for a single standalone account.
  Pre-setup (one-time, in the AWS Console, before `aws configure` will have anything to enter):
  1. **IAM → Users → Create user** — programmatic/CLI use, no console access needed.
  2. Attach a permissions policy — `AdministratorAccess` is simplest to unblock a
     workshop/test deployment; scope it down later once the exact Terraform-required
     permissions are known.
  3. Open the new user → **Security credentials** tab → **Create access key** → use case
     **Command Line Interface (CLI)** → copy the Access Key ID and Secret Access Key (the
     secret is shown once — never have the user paste it into chat, it goes straight into
     their own terminal).

If unclear which applies, ask the user directly (e.g. "does your AWS account belong to an AWS
Organization with SSO/Identity Center set up, or is this a standalone account?") rather than
guessing.

## After the user runs a manual step

Re-run this skill (or `3.2-check-prerequisites`) to confirm `aws sts get-caller-identity` now
succeeds before moving on.

## Constraints

- Never asks the user for, types, or echoes an AWS access key or secret key — those only ever
  go directly from the user's terminal into the `aws` CLI's own prompts.
- Only ever runs `aws sso login` (browser-mediated, no secret in transit here) and read-only
  identity checks. `aws configure` / `aws configure sso` are always left for the user to run
  themselves.
