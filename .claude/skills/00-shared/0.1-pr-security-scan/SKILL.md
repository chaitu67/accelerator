---
name: 0.1-pr-security-scan
description: Scaffold a generic GitHub Actions workflow (security-scan.yml) that runs a security scan -- secrets, IaC misconfiguration, dependency vulnerabilities -- on every pull request, in any repo, with no path filter and no dependency on the 01-05 Databricks/Terraform setup sequence. Posts results as a PR comment; fails the check only on CRITICAL/HIGH severity findings. Use when the user asks to add a security scan, vulnerability scan, secrets scan, or IaC misconfiguration check that runs on all PRs before merging to prod.
---

# PR Security Scan (any repo)

Part of `00-shared` — see [../README.md](../README.md) for why this group has no dependency on
`01`–`05`: this workflow scans repo *content* generically (whatever files exist), not
Databricks/Terraform-specific setup, so it works standalone in any repo from day one.

## What it does

- Scaffolds `.github/workflows/security-scan.yml`, triggered on **every** `pull_request` (no
  `paths:` filter — unlike `terraform-plan.yml`, which only fires on `infrastructure/**`
  changes). Runs [Trivy](https://aquasecurity.github.io/trivy/) in filesystem-scan mode across
  three scanner types in one pass:
  - `secret` — hardcoded credentials/tokens/keys anywhere in the repo.
  - `misconfig` — IaC misconfiguration (Terraform, CloudFormation, Kubernetes manifests, Dockerfiles,
    etc. — if present): public S3 buckets, wildcard IAM policy actions/resources, unencrypted
    resources, security groups open to `0.0.0.0/0`, and similar.
  - `vuln` — known CVEs in dependency manifests/lockfiles (e.g. `requirements.txt`,
    `package-lock.json`) and any container images referenced.
- Posts the full report (all severities — CRITICAL through UNKNOWN) as a PR comment every time,
  so lower-severity findings stay visible for awareness even though they don't block.
- **Fails the check only if a CRITICAL or HIGH severity finding exists** (a second, gating-only
  Trivy invocation) — not on any finding at all, and not merely advisory either. This was an
  explicit choice: advisory-only risks findings being ignored; failing on *any* finding (however
  minor) risks enough false-positive friction that people route around the gate entirely.
- Scaffolds an empty `.trivyignore` at the repo root alongside it, for suppressing accepted-risk
  findings by CVE/rule ID (with a comment explaining why) instead of editing the workflow itself.

## Running it

```
bash .claude/skills/00-shared/0.1-pr-security-scan/scaffold.sh [path-to-target-repo]
```

Defaults to `$WORKSPACE_ROOT/databricks` (the sibling repo) if no path is given — pass an
explicit path to scaffold this into a different repo. Idempotent: never overwrites
`security-scan.yml` or `.trivyignore` if either already exists in the target repo.

## Why the PR-comment step reads Trivy's output from a file, not a GitHub Actions expression

This project has twice broken a PR-comment step by interpolating tool output containing literal
`${...}` sequences (IAM policy JSON, in both cases) directly into a JS template literal via
`${{ steps.X.outputs.stdout }}` — see `04-github-cicd/4.4-create-workflows`'s SKILL.md for that
history. Trivy misconfiguration findings routinely quote IAM policy snippets too, so the same
class of bug is very plausible here. Rather than reapply the env-var workaround used there, this
workflow sidesteps the problem entirely: Trivy writes its report to a file
(`trivy-report.txt`), and the `actions/github-script` step reads that file directly with Node's
`fs` module — no GitHub Actions expression or template-literal interpolation of scanner output
at all. Prefer this file-read pattern over the env-var pattern when the tool being wrapped can
write its output to a file (not every tool can, e.g. `terraform plan` cannot easily be redirected
in the middle of the same invocation that also needs to save a plan file).

## Constraints

- Never overwrites an existing `security-scan.yml`/`.trivyignore` — if the user wants to change
  the scan, edit the file directly rather than re-running this skill.
- Never blocks the whole check on low/medium/unknown-severity findings — those are visible in
  the PR comment for awareness, not enforced. If the user wants stricter gating, that's a
  deliberate choice to raise with them (change `severity: CRITICAL,HIGH` in the gating step),
  not something to silently tighten.
- Never edits `.trivyignore` on the user's behalf to suppress a real finding — that file is for
  the user (or whoever reviews the PR) to decide is an accepted risk, with a reason, not a tool
  to make CI green.
- Runs on every PR, no path filter — deliberate, since "generic... across all PRs" was the
  explicit ask; don't scope this down to `infrastructure/**` or any other subset without being
  asked.
