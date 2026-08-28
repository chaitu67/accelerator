#!/usr/bin/env bash
# Idempotent scaffold for the databricks repo's infrastructure/ Terraform project.
# If infrastructure/ already exists, it is left untouched and reused as-is.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCELERATOR_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel)"
WORKSPACE_ROOT="$(dirname "$ACCELERATOR_ROOT")"
DATABRICKS_REPO="$WORKSPACE_ROOT/databricks"
INFRA_DIR="$DATABRICKS_REPO/infrastructure"

if [ ! -d "$DATABRICKS_REPO" ]; then
  echo "Error: databricks repo not found at $DATABRICKS_REPO" >&2
  echo "Run the 01-clone-sibling-repo skill first to check it out as a sibling of accelerator." >&2
  exit 1
fi

if [ -d "$INFRA_DIR" ]; then
  echo "infrastructure/ already exists at $INFRA_DIR — reusing it as-is, nothing scaffolded."
  exit 0
fi

echo "Creating Terraform project at $INFRA_DIR"
mkdir -p "$INFRA_DIR"

cat > "$INFRA_DIR/versions.tf" <<'EOF'
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
EOF

cat > "$INFRA_DIR/backend.tf" <<'EOF'
# Local state is used today (no backend block below = local backend).
#
# To move to a remote S3 backend later, uncomment and fill in the values below,
# then run `terraform init -migrate-state` to migrate existing local state:
#
# terraform {
#   backend "s3" {
#     bucket         = "<state-bucket-name>"
#     key            = "databricks/infrastructure/terraform.tfstate"
#     region         = "<aws-region>"
#     dynamodb_table = "<lock-table-name>"
#     encrypt        = true
#   }
# }
EOF

cat > "$INFRA_DIR/providers.tf" <<'EOF'
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

provider "databricks" {
  # profile-based OAuth (local use, default) vs. github-oidc workload identity
  # federation (GitHub Actions CI, set via TF_VAR_databricks_auth_type -- see
  # 04-github-cicd/4.3-configure-github-oidc). profile is left null under
  # github-oidc so it doesn't try to load a local ~/.databrickscfg profile
  # that doesn't exist on a CI runner.
  auth_type = var.databricks_auth_type
  profile   = var.databricks_auth_type == null ? var.databricks_profile : null
  client_id = var.databricks_client_id
  host      = var.databricks_host
  token     = var.databricks_token
}
EOF

cat > "$INFRA_DIR/variables.tf" <<'EOF'
variable "aws_region" {
  description = "AWS region to deploy Databricks-related infrastructure into."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to authenticate with. Leave null to use the default credential chain."
  type        = string
  default     = null
}

variable "databricks_profile" {
  description = "~/.databrickscfg profile for the default (non-account) Databricks provider. Populated by `databricks auth login` (OAuth) via the 3.2.2-authenticate-databricks skill -- the 'DEFAULT' profile is used unless a workspace host/token override below is set."
  type        = string
  default     = "DEFAULT"
}

variable "databricks_host" {
  description = "Databricks workspace URL, e.g. https://<workspace>.cloud.databricks.com. Only needed to override the profile above with explicit host+token (PAT) auth; leave null to use databricks_profile."
  type        = string
  default     = null
}

variable "databricks_token" {
  description = "Databricks personal access token, only used if databricks_host is also set. Pass via TF_VAR_databricks_token or a gitignored .tfvars file -- never commit it. Leave null to use databricks_profile (OAuth) instead."
  type        = string
  sensitive   = true
  default     = null
}

variable "databricks_auth_type" {
  description = "Explicit Databricks provider auth type override. Set to \"github-oidc\" for GitHub Actions workload identity federation (paired with databricks_client_id below; no stored secret) -- set via TF_VAR_databricks_auth_type in the GitHub Actions workflow, per the 04-github-cicd skill group. Leave null for local use, which falls back to databricks_profile (or databricks_host/databricks_token)."
  type        = string
  default     = null
}

variable "databricks_client_id" {
  description = "Application ID (client ID -- not a secret) of the Databricks service principal used for GitHub Actions workload identity federation. Only read when databricks_auth_type = \"github-oidc\"; set via TF_VAR_databricks_client_id (a plain GitHub Actions repo variable, since it grants no access by itself)."
  type        = string
  default     = null
}
EOF

cat > "$INFRA_DIR/main.tf" <<'EOF'
# Databricks infrastructure resources go here.
# Intentionally empty — real resources are added by the 05-databricks-terraform-deployment
# skill group, after 03-terraform-setup (this scaffold) and 04-github-cicd (CI/CD) are in place.
EOF

cat > "$INFRA_DIR/outputs.tf" <<'EOF'
# Outputs for downstream skills/consumers go here as resources are added.
EOF

cat > "$INFRA_DIR/terraform.tfvars.example" <<'EOF'
aws_region         = "us-east-1"
aws_profile        = "default"
# Default auth: `databricks auth login` (via the 3.2.2-authenticate-databricks skill)
# saves an OAuth profile named DEFAULT to ~/.databrickscfg -- nothing else to set here.
databricks_profile = "DEFAULT"
# Only needed to override the profile above with PAT auth instead:
# databricks_host = "https://<workspace>.cloud.databricks.com"
# databricks_token is sensitive - set via TF_VAR_databricks_token env var
# or a gitignored terraform.tfvars, never commit it.
EOF

cat > "$INFRA_DIR/.gitignore" <<'EOF'
.terraform/
*.tfstate
*.tfstate.*
terraform.tfvars
override.tf
override.tf.json
crash.log
EOF

echo "Terraform project scaffolded at $INFRA_DIR"
