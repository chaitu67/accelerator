#!/usr/bin/env bash
# Idempotent bootstrap of the S3 bucket (and, optionally, DynamoDB lock
# table) that will hold the databricks/infrastructure Terraform project's
# remote state. Plain AWS CLI calls, not Terraform -- this project can't
# create the very backend it needs to initialize against.
set -euo pipefail

BUCKET="${1:-}"
REGION="${2:-}"
TABLE="${3:-}" # optional -- omit to use S3-native locking (use_lockfile) instead

if [ -z "$BUCKET" ] || [ -z "$REGION" ]; then
  echo "Usage: bootstrap.sh <bucket-name> <region> [lock-table-name]" >&2
  echo "  Omit lock-table-name to use S3-native locking (Terraform >= 1.10) instead of DynamoDB." >&2
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI not installed -> run the 02-setup-local-env skill first." >&2
  exit 1
fi

echo "== S3 state bucket: $BUCKET (region: $REGION) =="
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "already exists -- reusing as-is."
else
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
  echo "created."
fi

echo "  enabling versioning..."
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

echo "  enabling default server-side encryption (AES256)..."
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

echo "  blocking public access..."
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

if [ -n "$TABLE" ]; then
  echo
  echo "== DynamoDB lock table: $TABLE (region: $REGION) =="
  if aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" >/dev/null 2>&1; then
    echo "already exists -- reusing as-is."
  else
    aws dynamodb create-table \
      --table-name "$TABLE" \
      --region "$REGION" \
      --attribute-definitions AttributeName=LockID,AttributeType=S \
      --key-schema AttributeName=LockID,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST >/dev/null
    echo "created. waiting for it to become ACTIVE..."
    aws dynamodb wait table-exists --table-name "$TABLE" --region "$REGION"
    echo "active."
  fi
else
  echo
  echo "== Lock table: skipped -- using S3-native locking (use_lockfile) instead =="
  echo "Requires Terraform >= 1.10 for every consumer (this laptop and CI); versions.tf's"
  echo "required_version should already reflect that (bumped by this skill's SKILL.md notes)."
fi

echo
if [ -n "$TABLE" ]; then
  echo "Bootstrap complete: bucket '$BUCKET' and table '$TABLE' are ready in $REGION."
else
  echo "Bootstrap complete: bucket '$BUCKET' is ready in $REGION (S3-native locking, no table)."
fi
echo "Next: run migrate.sh $BUCKET $REGION${TABLE:+ $TABLE}"
