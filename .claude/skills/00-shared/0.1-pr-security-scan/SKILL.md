---
name: 0.1-pr-security-scan
description: Scaffold a generic GitHub Actions workflow (security-scan.yml) that runs a Checkov (Python) security scan -- secrets, IaC misconfiguration -- on every pull request, in any repo, with no path filter and no dependency on the 01-05 Databricks/Terraform setup sequence. Posts results as a PR comment; fails the check only if a curated set of critical checks fails. Use when the user asks to add a security scan, secrets scan, or IaC misconfiguration check that runs on all PRs before merging to prod.
---

# PR Security Scan (any repo)

Part of `00-shared` — see [../README.md](../README.md) for why this group has no dependency on
`01`–`05`: this workflow scans repo *content* generically (whatever files exist), not
Databricks/Terraform-specific setup, so it works standalone in any repo from day one.

## What it does

- Scaffolds `.github/workflows/security-scan.yml`, triggered on **every** `pull_request` (no
  `paths:` filter — unlike `terraform-plan.yml`, which only fires on `infrastructure/**`
  changes). Runs [Checkov](https://www.checkov.io/) (Python, `pip install`-ed in the workflow —
  no third-party GitHub Action wrapper needed beyond first-party `actions/*`) across two
  frameworks in one pass:
  - `secrets` — hardcoded credentials/tokens/keys anywhere in the repo.
  - `terraform` (plus whatever other IaC frameworks Checkov auto-detects — CloudFormation,
    Kubernetes manifests, Dockerfiles, etc., if present) — public S3 buckets, wildcard IAM policy
    actions/resources, unencrypted resources, publicly-assumable IAM roles, and similar.
  - **Does not** do dependency-vulnerability (SCA) scanning — Checkov's `sca_package`/`sca_image`
    frameworks refuse to run at all without a paid Bridgecrew/Prisma Cloud API key
    (`ModuleNotEnabledError`, confirmed empirically), and this skill deliberately doesn't add
    that account/secret dependency. If dependency scanning matters for the target repo, add a
    separate tool alongside (e.g. Trivy in vuln-only mode, or GitHub's own Dependabot).
- Posts the full report as a PR comment every time (via `--soft-fail`, so this step alone never
  blocks), so lower-severity findings stay visible for awareness even though they don't gate.
- **Fails the check only if one of a curated set of check IDs fails** (`CRITICAL_CHECKS` in the
  workflow, passed to a second, gating-only Checkov invocation via `-c`) — wildcard IAM admin
  policies, publicly-assumable IAM roles, S3 buckets without encryption or with any public-access
  setting, and every hardcoded-secret detector. **This list is hand-curated, not computed from
  severity**: confirmed empirically that free/open-source Checkov assigns no severity to any
  check at all (`severity: None` on every finding in JSON output; real severity data is a paid
  Bridgecrew/Prisma Cloud platform feature) — `--hard-fail-on CRITICAL`/`HIGH` silently never
  fires with the free CLI, so it can't be used the way `5.1`'s Trivy-based predecessor of this
  workflow did. Review `CRITICAL_CHECKS` whenever `CHECKOV_VERSION` is bumped — new secret
  detectors in particular get new `CKV_SECRET_<N>` ids that won't automatically be included.
- Scaffolds an empty (commented-out example) `.checkov.yaml` at the repo root alongside it, for
  suppressing accepted-risk findings by check ID (with a comment explaining why) instead of
  editing the workflow itself. Confirmed Checkov auto-discovers this file from the scan
  directory without needing `--config-file`; both YAML-list and comma-string `skip-check` syntax
  work.

## Running it

```
bash .claude/skills/00-shared/0.1-pr-security-scan/scaffold.sh [path-to-target-repo]
```

Defaults to `$WORKSPACE_ROOT/databricks` (the sibling repo) if no path is given — pass an
explicit path to scaffold this into a different repo. Idempotent: never overwrites
`security-scan.yml` or `.checkov.yaml` if either already exists in the target repo.

## Why the PR-comment step reads Checkov's output from a file, not a GitHub Actions expression

This project has twice broken a PR-comment step by interpolating tool output containing literal
`${...}` sequences (IAM policy JSON, in both cases) directly into a JS template literal via
`${{ steps.X.outputs.stdout }}` — see `04-github-cicd/4.4-create-workflows`'s SKILL.md for that
history. Checkov misconfiguration findings routinely quote IAM policy snippets too, so the same
class of bug is very plausible here. Rather than reapply the env-var workaround used there, this
workflow sidesteps the problem entirely: Checkov writes its report to a file
(`checkov-report/results_cli.txt`), and the `actions/github-script` step reads that file directly
with Node's `fs` module — no GitHub Actions expression or template-literal interpolation of
scanner output at all. Prefer this file-read pattern over the env-var pattern when the tool being
wrapped can write its output to a file (not every tool can, e.g. `terraform plan` cannot easily
be redirected in the middle of the same invocation that also needs to save a plan file).

## Constraints

- Never overwrites an existing `security-scan.yml`/`.checkov.yaml` — if the user wants to change
  the scan, edit the file directly rather than re-running this skill.
- Never blocks the whole check on a finding outside `CRITICAL_CHECKS` — those are visible in the
  PR comment for awareness, not enforced. If the user wants stricter or looser gating, that's a
  deliberate choice to raise with them (edit `CRITICAL_CHECKS` in the workflow), not something to
  silently tighten or loosen.
- Never edits `.checkov.yaml` on the user's behalf to suppress a real finding — that file is for
  the user (or whoever reviews the PR) to decide is an accepted risk, with a reason, not a tool
  to make CI green.
- Never adds a Bridgecrew/Prisma Cloud API key to unlock severity data or SCA scanning without
  the user explicitly asking for it — that's a new external account/secret dependency, a
  deliberate scope decision this skill defaults away from.
- Runs on every PR, no path filter — deliberate, since "generic... across all PRs" was the
  explicit ask; don't scope this down to `infrastructure/**` or any other subset without being
  asked.
