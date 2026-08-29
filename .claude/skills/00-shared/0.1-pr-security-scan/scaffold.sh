#!/usr/bin/env bash
# Idempotent scaffold of a generic security-scan GitHub Actions workflow. Never
# overwrites an existing file with either name -- same convention as
# 04-github-cicd/4.4-create-workflows/scaffold.sh. Unlike that skill, this one has
# no dependency on the sibling repo already having infrastructure/, a remote
# backend, or OIDC set up -- it only needs the target repo to exist and be a git
# repo, since it scans repo content generically (any language, any file type),
# not Terraform specifically.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCELERATOR_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel)"
WORKSPACE_ROOT="$(dirname "$ACCELERATOR_ROOT")"
TARGET_REPO="${1:-$WORKSPACE_ROOT/databricks}"
WORKFLOWS_DIR="$TARGET_REPO/.github/workflows"

if [ ! -d "$TARGET_REPO/.git" ]; then
  echo "Error: target repo not found at $TARGET_REPO (or not a git repo)." >&2
  echo "Usage: scaffold.sh [path-to-target-repo]  (default: \$WORKSPACE_ROOT/databricks)" >&2
  exit 1
fi

mkdir -p "$WORKFLOWS_DIR"
WROTE_ANY=0

WORKFLOW_FILE="$WORKFLOWS_DIR/security-scan.yml"
if [ -f "$WORKFLOW_FILE" ]; then
  echo "security-scan.yml already exists -- reusing it as-is, not overwritten."
else
  cat > "$WORKFLOW_FILE" <<'EOF'
# Generic security scan -- runs on EVERY pull request, no path filter, regardless
# of what changed or which repo this is scaffolded into. Unlike terraform-plan.yml
# (scoped to infrastructure/**, Terraform-specific), this has no dependency on any
# other CI/CD setup in this repo -- it works standalone from day one.
#
# Uses Checkov (Python, pip-installed -- no third-party GitHub Action wrapper
# needed beyond first-party actions/*) for IaC misconfiguration (public S3
# buckets, wildcard IAM policies, unencrypted resources, etc. -- if the repo has
# Terraform/CloudFormation/K8s manifests) and hardcoded-secret scanning. Always
# posts a full report as a PR comment; only fails the check if one of a curated
# set of genuinely severe checks fails (see CRITICAL_CHECKS below) -- everything
# else is visible for awareness but doesn't block.
#
# Does NOT do dependency-vulnerability (SCA) scanning: Checkov's sca_package/
# sca_image frameworks require a paid Bridgecrew/Prisma Cloud API key and refuse
# to run without one ("ModuleNotEnabledError", confirmed empirically) -- a
# deliberate scope tradeoff to avoid a new external account/secret dependency,
# not an oversight. If dependency scanning is needed, that's a separate tool
# (e.g. Trivy in vuln-only mode, or GitHub's own Dependabot) to add alongside.
#
# Why a curated check-ID list instead of severity thresholds: free/open-source
# Checkov does not assign severity levels to checks at all (also a paid-platform
# feature) -- confirmed empirically: --hard-fail-on CRITICAL silently never
# fires with the free CLI, since every check's severity is None in the JSON
# output. CRITICAL_CHECKS below is the workaround, curated by hand rather than
# computed. Review it whenever CHECKOV_VERSION is bumped -- new secret
# detectors in particular get new CKV_SECRET_<N> ids that won't automatically
# be included.
name: Security Scan

on:
  pull_request:

permissions:
  contents: read
  pull-requests: write # required to post the scan report as a PR comment

jobs:
  scan:
    runs-on: ubuntu-latest
    env:
      CHECKOV_VERSION: "3.3.15"
      # Wildcard IAM admin policies (CKV_AWS_1/62), publicly-assumable IAM
      # roles (CKV_AWS_60), S3 buckets without encryption (CKV_AWS_19) or with
      # any public-access setting (CKV_AWS_20/53/54/55/56/57), and every
      # hardcoded-secret detector (all CKV_SECRET_* ids as of checkov 3.3.15).
      CRITICAL_CHECKS: "CKV_AWS_1,CKV_AWS_19,CKV_AWS_20,CKV_AWS_53,CKV_AWS_54,CKV_AWS_55,CKV_AWS_56,CKV_AWS_57,CKV_AWS_60,CKV_AWS_62,CKV_SECRET_1,CKV_SECRET_2,CKV_SECRET_3,CKV_SECRET_4,CKV_SECRET_5,CKV_SECRET_6,CKV_SECRET_7,CKV_SECRET_8,CKV_SECRET_9,CKV_SECRET_10,CKV_SECRET_11,CKV_SECRET_12,CKV_SECRET_13,CKV_SECRET_14,CKV_SECRET_15,CKV_SECRET_16,CKV_SECRET_17,CKV_SECRET_18,CKV_SECRET_19,CKV_SECRET_30,CKV_SECRET_40,CKV_SECRET_48,CKV_SECRET_49,CKV_SECRET_80,CKV_SECRET_116,CKV_SECRET_192,CKV_SECRET_380,CKV_SECRET_381"
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4

      - uses: actions/setup-python@a26af69be951a213d495a4c3e4e4022e16d87065 # v5
        with:
          python-version: "3.12"

      - name: Install Checkov
        run: pip install "checkov==${{ env.CHECKOV_VERSION }}"

      - name: Checkov scan (full report, all findings, never fails the job)
        run: >
          checkov -d . --framework terraform,secrets -o cli
          --output-file-path checkov-report --compact --soft-fail

      - name: Post scan report as PR comment
        uses: actions/github-script@f28e40c7f34bde8b3046d885e986cb6290c5673b # v7
        with:
          script: |
            const fs = require('fs');
            // Read the report directly from the file Checkov wrote, rather than
            // passing it through any GitHub Actions expression/env var -- avoids
            // the class of bug hit twice already in this project, where scanner/
            // plan output containing literal ${...} sequences (e.g. an IAM policy
            // condition, or a flagged env-var reference) breaks a JS template
            // literal if interpolated into the workflow YAML directly.
            let report = fs.readFileSync('checkov-report/results_cli.txt', 'utf8');
            const MAX_LEN = 60000; // stay under GitHub's ~65536-byte comment limit
            if (report.length > MAX_LEN) {
              report = report.slice(0, MAX_LEN) + '\n... (truncated -- see the full report in this run\'s logs)';
            }
            const output = `#### Security Scan (Checkov)\n\`\`\`\n${report}\n\`\`\``;
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: output,
            });

      - name: Checkov scan (gate on curated critical checks only)
        id: gate
        continue-on-error: true
        run: >
          checkov -d . --framework terraform,secrets -c "${{ env.CRITICAL_CHECKS }}"

      - name: Fail if a critical check failed
        if: steps.gate.outcome == 'failure'
        run: |
          echo "One or more critical checks failed -- see the Security Scan PR comment above (or this run's logs) for details." >&2
          exit 1
EOF
  echo "Created $WORKFLOW_FILE"
  WROTE_ANY=1
fi

CHECKOVIGNORE_FILE="$TARGET_REPO/.checkov.yaml"
if [ -f "$CHECKOVIGNORE_FILE" ]; then
  echo ".checkov.yaml already exists -- reusing it as-is, not overwritten."
else
  cat > "$CHECKOVIGNORE_FILE" <<'EOF'
# Checkov config file -- primarily for suppressing accepted-risk findings by
# check ID, with a comment explaining why, rather than editing security-scan.yml
# to weaken the scan itself. Applies to both the report and gate steps.
# https://www.checkov.io/2.Concepts/Suppressions.html
#
# IMPORTANT: this file must always parse to a real YAML mapping, never end up
# empty/comments-only -- Checkov's config loader hard-errors (exit code 2, a
# crash, not a normal "findings failed" exit) if this file exists but
# yaml.load() returns None instead of a dict. Confirmed live: the very first
# CI run of this workflow crashed on exactly this before `skip-check: ""` was
# added as a real, harmless (skips nothing) baseline key.
skip-check: ""
# To add real entries instead of the harmless default above, use either
# comma-string or list syntax (both confirmed to work), for example:
# skip-check: "CKV_AWS_999,CKV_AWS_998"  # example -- explain why here
EOF
  echo "Created $CHECKOVIGNORE_FILE"
  WROTE_ANY=1
fi

echo
if [ "$WROTE_ANY" -eq 1 ]; then
  echo "Security scan workflow scaffolded in $WORKFLOWS_DIR."
  echo "It runs on every PR automatically from the next PR onward -- nothing else to configure."
else
  echo "Nothing to do -- both files already scaffolded."
fi
