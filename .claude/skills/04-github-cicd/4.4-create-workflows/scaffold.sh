#!/usr/bin/env bash
# Idempotent scaffold of the two GitHub Actions workflow files for
# databricks/infrastructure. Never overwrites an existing workflow file with
# either name -- same convention as 3.1-scaffold-infrastructure's init.sh.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCELERATOR_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel)"
WORKSPACE_ROOT="$(dirname "$ACCELERATOR_ROOT")"
DATABRICKS_REPO="$WORKSPACE_ROOT/databricks"
WORKFLOWS_DIR="$DATABRICKS_REPO/.github/workflows"

if [ ! -d "$DATABRICKS_REPO/.git" ]; then
  echo "Error: databricks repo not found at $DATABRICKS_REPO -> run 01-clone-sibling-repo first." >&2
  exit 1
fi
if [ ! -d "$DATABRICKS_REPO/infrastructure" ]; then
  echo "Error: infrastructure/ not found -> run 3.1-scaffold-infrastructure first." >&2
  exit 1
fi

mkdir -p "$WORKFLOWS_DIR"
WROTE_ANY=0

PLAN_FILE="$WORKFLOWS_DIR/terraform-plan.yml"
if [ -f "$PLAN_FILE" ]; then
  echo "terraform-plan.yml already exists -- reusing it as-is, not overwritten."
else
  cat > "$PLAN_FILE" <<'EOF'
# Read-only: fmt check + validate + plan on every PR touching infrastructure/.
# Never runs apply. Posts the plan output as a PR comment so reviewers see
# exactly what would change. Both AWS and Databricks auth are OIDC/workload
# identity federation -- no long-lived key or secret anywhere in this workflow.
# See the 04-github-cicd skill group (accelerator/.claude/skills/04-github-cicd).
name: Terraform Plan

on:
  pull_request:
    paths:
      - "infrastructure/**"

permissions:
  id-token: write   # required for AWS OIDC + Databricks workload identity federation
  contents: read
  pull-requests: write # required to post the plan as a PR comment

defaults:
  run:
    working-directory: infrastructure

jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4

      - uses: aws-actions/configure-aws-credentials@7474bc4690e29a8392af63c5b98e7449536d5c3a # v4
        with:
          role-to-assume: ${{ vars.AWS_ROLE_TO_ASSUME }}
          aws-region: ${{ vars.AWS_REGION }}

      - uses: hashicorp/setup-terraform@b9cd54a3c349d3f38e8881555d616ced269862dd # v3

      - name: Terraform fmt (check only)
        run: terraform fmt -check -recursive

      - name: Terraform init
        run: terraform init -input=false

      - name: Terraform validate
        run: terraform validate

      - name: Terraform plan
        id: plan
        env:
          TF_VAR_databricks_host: ${{ vars.DATABRICKS_HOST }}
          TF_VAR_databricks_auth_type: github-oidc
          TF_VAR_databricks_client_id: ${{ vars.DATABRICKS_CLIENT_ID }}
          # Non-secret, per-deployment config (account IDs, workspace names/regions/buckets,
          # etc.) should NOT be added here as TF_VAR_*/repo variables -- put it in a committed
          # *.auto.tfvars/*.auto.tfvars.json file instead. Terraform auto-loads those from the
          # checked-out repo, locally and in CI, with zero workflow edits ever needed again.
          # Reserve this env block for genuinely cross-cutting CI identity plumbing (how CI
          # authenticates), which legitimately differs per environment.
        run: terraform plan -input=false -no-color
        continue-on-error: true

      - name: Post plan output as PR comment
        uses: actions/github-script@f28e40c7f34bde8b3046d885e986cb6290c5673b # v7
        env:
          # Pass the plan text through an env var rather than interpolating
          # `${{ steps.plan.outputs.stdout }}` directly into the JS template literal below --
          # Terraform plan output for IAM policy resources routinely contains literal
          # `${aws:...}` policy-variable syntax, which breaks the JS parser
          # ("Unexpected identifier") if substituted straight into the template string.
          PLAN: ${{ steps.plan.outputs.stdout }}
        with:
          script: |
            const output = `#### Terraform Plan
            \`\`\`
            ${process.env.PLAN}
            \`\`\``;
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: output,
            });

      - name: Fail if plan errored
        if: steps.plan.outcome == 'failure'
        run: exit 1
EOF
  echo "Created $PLAN_FILE"
  WROTE_ANY=1
fi

APPLY_FILE="$WORKFLOWS_DIR/terraform-apply.yml"
if [ -f "$APPLY_FILE" ]; then
  echo "terraform-apply.yml already exists -- reusing it as-is, not overwritten."
else
  cat > "$APPLY_FILE" <<'EOF'
# Applies infrastructure/ on merge to main. Gated on the "production" GitHub
# Environment -- if it has required reviewers configured (Settings >
# Environments in this repo), the job pauses for manual approval before
# running. Without that Environment protection set up, this runs unattended
# on every merge -- see 4.4-create-workflows/SKILL.md before relying on this.
# Always plans to a saved file first, then applies exactly that saved plan.
name: Terraform Apply

on:
  push:
    branches: [main]
    paths:
      - "infrastructure/**"

permissions:
  id-token: write   # required for AWS OIDC + Databricks workload identity federation
  contents: read

defaults:
  run:
    working-directory: infrastructure

jobs:
  apply:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4

      - uses: aws-actions/configure-aws-credentials@7474bc4690e29a8392af63c5b98e7449536d5c3a # v4
        with:
          role-to-assume: ${{ vars.AWS_ROLE_TO_ASSUME }}
          aws-region: ${{ vars.AWS_REGION }}

      - uses: hashicorp/setup-terraform@b9cd54a3c349d3f38e8881555d616ced269862dd # v3

      - name: Terraform init
        run: terraform init -input=false

      - name: Terraform plan
        env:
          TF_VAR_databricks_host: ${{ vars.DATABRICKS_HOST }}
          TF_VAR_databricks_auth_type: github-oidc
          TF_VAR_databricks_client_id: ${{ vars.DATABRICKS_CLIENT_ID }}
          # See the matching comment in terraform-plan.yml -- non-secret, per-deployment
          # config belongs in a committed *.auto.tfvars file, not here.
        run: terraform plan -input=false -out=tfplan

      - name: Terraform apply (the plan just produced, nothing else)
        run: terraform apply -input=false -auto-approve tfplan
EOF
  echo "Created $APPLY_FILE"
  WROTE_ANY=1
fi

echo
if [ "$WROTE_ANY" -eq 1 ]; then
  echo "Workflow files scaffolded in $WORKFLOWS_DIR."
  echo "Before merging anything that would trigger terraform-apply.yml, make sure a"
  echo "'production' GitHub Environment with required reviewers exists (Settings > Environments"
  echo "in the databricks repo on GitHub) -- otherwise apply runs unattended on every merge."
else
  echo "Nothing to do -- both workflow files already exist."
fi
