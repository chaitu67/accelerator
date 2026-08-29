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
# Scans for (in one pass, via Trivy): known dependency vulnerabilities, IaC
# misconfiguration (public S3 buckets, wildcard IAM policies, unencrypted
# resources, etc. -- if the repo has Terraform/CloudFormation/K8s manifests),
# and hardcoded secrets. Always posts a full report as a PR comment; only fails
# the check on CRITICAL/HIGH severity findings (see the second scan step below)
# -- lower severities are visible for awareness but don't block.
#
# False positives / accepted risks: add a rule to .trivyignore at the repo root
# (created empty alongside this workflow) rather than editing this file.
name: Security Scan

on:
  pull_request:

permissions:
  contents: read
  pull-requests: write # required to post the scan report as a PR comment

jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Trivy scan (full report, all severities)
        uses: aquasecurity/trivy-action@v0.36.0
        with:
          scan-type: fs
          scanners: vuln,secret,misconfig
          format: table
          output: trivy-report.txt
          severity: CRITICAL,HIGH,MEDIUM,LOW,UNKNOWN
          exit-code: 0

      - name: Post scan report as PR comment
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            // Read the report directly from the file Trivy wrote, rather than
            // passing it through any GitHub Actions expression/env var -- avoids
            // the class of bug hit twice already in this project, where scanner/
            // plan output containing literal ${...} sequences (e.g. an IAM policy
            // condition, or a flagged env-var reference) breaks a JS template
            // literal if interpolated into the workflow YAML directly.
            let report = fs.readFileSync('trivy-report.txt', 'utf8');
            const MAX_LEN = 60000; // stay under GitHub's ~65536-byte comment limit
            if (report.length > MAX_LEN) {
              report = report.slice(0, MAX_LEN) + '\n... (truncated -- see the full report in this run\'s logs)';
            }
            const output = `#### Security Scan (Trivy)\n\`\`\`\n${report}\n\`\`\``;
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: output,
            });

      - name: Trivy scan (gate on CRITICAL/HIGH only)
        id: gate
        uses: aquasecurity/trivy-action@v0.36.0
        continue-on-error: true
        with:
          scan-type: fs
          scanners: vuln,secret,misconfig
          format: table
          severity: CRITICAL,HIGH
          exit-code: 1

      - name: Fail if CRITICAL/HIGH findings exist
        if: steps.gate.outcome == 'failure'
        run: |
          echo "CRITICAL/HIGH severity findings detected -- see the Security Scan PR comment above (or this run's logs) for details." >&2
          exit 1
EOF
  echo "Created $WORKFLOW_FILE"
  WROTE_ANY=1
fi

TRIVYIGNORE_FILE="$TARGET_REPO/.trivyignore"
if [ -f "$TRIVYIGNORE_FILE" ]; then
  echo ".trivyignore already exists -- reusing it as-is, not overwritten."
else
  cat > "$TRIVYIGNORE_FILE" <<'EOF'
# Trivy findings to suppress, one per line -- either a CVE ID (e.g. CVE-2023-12345)
# or a specific rule ID (e.g. AVD-AWS-0001 for an IaC misconfiguration check).
# Add an entry here (with a comment explaining why it's an accepted risk, not a
# real fix) rather than editing security-scan.yml to weaken the scan itself.
# https://aquasecurity.github.io/trivy/latest/docs/configuration/filtering/#trivyignore
EOF
  echo "Created $TRIVYIGNORE_FILE"
  WROTE_ANY=1
fi

echo
if [ "$WROTE_ANY" -eq 1 ]; then
  echo "Security scan workflow scaffolded in $WORKFLOWS_DIR."
  echo "It runs on every PR automatically from the next PR onward -- nothing else to configure."
else
  echo "Nothing to do -- both files already scaffolded."
fi
