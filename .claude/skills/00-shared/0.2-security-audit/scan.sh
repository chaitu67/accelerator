#!/usr/bin/env bash
# Gathers raw security-relevant signal about a target git repo and prints it to
# stdout as labelled sections. This script never judges severity or writes prose --
# that's SKILL.md's job (the agent reads this output, applies the scoring rubric,
# and writes the report). Keeping the mechanical gathering here and the judgment in
# SKILL.md mirrors this project's existing deploy.sh/SKILL.md split elsewhere.
#
# Repo-agnostic like the rest of 00-shared: every check below degrades gracefully
# (prints "not applicable"/"skipped", never errors out) when a given signal doesn't
# apply to the target repo -- e.g. no Terraform, no GitHub Actions, no `gh`/`aws`/
# `checkov` on PATH, or insufficient token scope for a given `gh api` call.
set -uo pipefail

TARGET_REPO="${1:-.}"
cd "$TARGET_REPO" 2>/dev/null || { echo "Error: cannot cd into '$TARGET_REPO'." >&2; exit 1; }
TARGET_REPO="$(pwd)"

if [ ! -d ".git" ]; then
  echo "Error: '$TARGET_REPO' is not a git repo (no .git/)." >&2
  exit 1
fi

echo "== TARGET =="
echo "path: $TARGET_REPO"
REMOTE_URL="$(git remote get-url origin 2>/dev/null || echo "")"
echo "remote: ${REMOTE_URL:-<none>}"
SLUG="$(echo "$REMOTE_URL" | sed -E 's#.*[:/]([^/]+/[^/]+)(\.git)?$#\1#; s/\.git$//')"
echo "gh slug guess: ${SLUG:-<could not parse>}"
echo

HAVE_GH=0
command -v gh >/dev/null 2>&1 && HAVE_GH=1

echo "== GITHUB REPO SETTINGS =="
if [ "$HAVE_GH" -eq 1 ] && [ -n "$SLUG" ]; then
  echo "-- visibility --"
  gh repo view "$SLUG" --json visibility,isPrivate 2>&1
  echo "-- security_and_analysis (secret scanning / dependabot / push protection) --"
  gh api "repos/$SLUG" --jq '.security_and_analysis' 2>&1
  echo "-- branch protection: main --"
  gh api "repos/$SLUG/branches/main/protection" --jq '{enforce_admins: .enforce_admins.enabled, required_approving_review_count: .required_pull_request_reviews.required_approving_review_count, dismiss_stale_reviews: .required_pull_request_reviews.dismiss_stale_reviews}' 2>&1
  echo "-- environments --"
  gh api "repos/$SLUG/environments" --jq '.environments[]? | {name, protection_rules}' 2>&1
else
  echo "skipped (gh CLI not available, or no parseable GitHub remote)"
fi
echo

echo "== HARDCODED SECRETS (tracked files) =="
git grep -nIE "AKIA[0-9A-Z]{16}|-----BEGIN [A-Z]+ PRIVATE KEY|(secret|token|password|apikey|api_key)[\"' ]*[:=][\"' ]*[A-Za-z0-9/+=_-]{16,}" -- . ':!*.lock' 2>/dev/null \
  | grep -viE "variable|description|^\s*#" \
  | head -50 || echo "(none found)"
echo

echo "== GITHUB ACTIONS WORKFLOWS =="
if [ -d ".github/workflows" ]; then
  for f in .github/workflows/*.yml .github/workflows/*.yaml; do
    [ -f "$f" ] || continue
    echo "-- $f --"
    echo "permissions block:"
    grep -n -A5 "^permissions:" "$f" || echo "  (none at top level -- check per-job blocks manually)"
    echo "action refs (unpinned = @<branch/tag>, pinned = @<40-hex-sha>):"
    grep -nE "uses:\s*[A-Za-z0-9._-]+/[A-Za-z0-9._-]+@" "$f" \
      | grep -vE "@[0-9a-f]{40}" || echo "  (all refs appear SHA-pinned)"
    echo "trigger types:"
    grep -nE "^\s*(pull_request|pull_request_target|push|schedule|workflow_dispatch):" "$f"
  done
else
  echo "not applicable (no .github/workflows/)"
fi
echo

echo "== TERRAFORM / IaC =="
TF_FILES="$(git ls-files '*.tf' 2>/dev/null)"
if [ -n "$TF_FILES" ]; then
  echo "Terraform files present ($(echo "$TF_FILES" | wc -l | tr -d ' ')). "
  if command -v checkov >/dev/null 2>&1; then
    echo "-- checkov (compact) --"
    checkov -d . --compact --quiet 2>&1 | tail -200
  else
    echo "checkov not installed locally (pip install checkov for a full local IaC scan)."
    echo "Falling back to the latest CI security-scan PR comment, if any:"
    if [ "$HAVE_GH" -eq 1 ] && [ -n "$SLUG" ]; then
      gh pr list --repo "$SLUG" --state all --limit 1 --json number -q '.[0].number' 2>/dev/null | while read -r PRNUM; do
        [ -n "$PRNUM" ] && gh pr view "$PRNUM" --repo "$SLUG" --json comments -q '.comments[-1].body' 2>&1 | head -100
      done
    fi
  fi
  echo "-- remote state backend (if any) --"
  grep -rn "backend \"s3\"" -A6 . --include="*.tf" 2>/dev/null || echo "(no S3 backend block found)"
else
  echo "not applicable (no .tf files tracked)"
fi
echo

echo "== AWS S3 HARDENING (only if aws CLI configured and buckets are named in Terraform) =="
if command -v aws >/dev/null 2>&1 && [ -n "$TF_FILES" ]; then
  BUCKETS="$(grep -rhoE '[A-Za-z_]*bucket[A-Za-z_]*\s*=\s*"[^"$][^"]*"' --include="*.tf" --include="*.auto.tfvars" . 2>/dev/null \
    | sed -E 's/.*"(.+)"/\1/' | sort -u)"
  if [ -z "$BUCKETS" ]; then
    echo "(no literal bucket names found -- likely computed/variable, check manually)"
  fi
  for B in $BUCKETS; do
    echo "-- $B --"
    aws s3api get-public-access-block --bucket "$B" 2>&1 | grep -v "^$"
    aws s3api get-bucket-encryption --bucket "$B" 2>&1 | grep -E "SSEAlgorithm|error|Error" | head -3
    aws s3api get-bucket-versioning --bucket "$B" 2>&1
  done
else
  echo "skipped (aws CLI not available, or no Terraform bucket names to check)"
fi
echo

echo "== DONE =="
