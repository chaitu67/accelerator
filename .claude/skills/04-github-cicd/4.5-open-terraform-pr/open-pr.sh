#!/usr/bin/env bash
# Commits uncommitted changes in the databricks repo to a branch (creating one
# if currently on the base branch), pushes it, and opens a PR against the base
# branch. Never pushes to the base branch directly, never merges anything --
# this is strictly branch -> commit -> push -> open PR, full stop.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCELERATOR_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel)"
WORKSPACE_ROOT="$(dirname "$ACCELERATOR_ROOT")"
DATABRICKS_REPO="$WORKSPACE_ROOT/databricks"

BRANCH_NAME="${1:-}"
COMMIT_MESSAGE="${2:-}"
PR_TITLE="${3:-}"
PR_BODY="${4:-Opened by the 4.5-open-terraform-pr skill.}"
BASE_BRANCH="${5:-main}"

if [ -z "$BRANCH_NAME" ] || [ -z "$PR_TITLE" ]; then
  echo "Usage: open-pr.sh <branch-name> <commit-message> <pr-title> [pr-body] [base-branch]" >&2
  echo "  commit-message may be \"\" only if there are no uncommitted changes to commit" >&2
  echo "  (i.e. the current branch already has unpushed commits ahead of origin/<base-branch>)." >&2
  exit 1
fi

if [ "$BRANCH_NAME" = "$BASE_BRANCH" ]; then
  echo "Error: branch-name and base-branch can't both be '$BASE_BRANCH' -- changes always go" >&2
  echo "through a separate branch, never straight onto $BASE_BRANCH." >&2
  exit 1
fi

if [ ! -d "$DATABRICKS_REPO/.git" ]; then
  echo "Error: databricks repo not found at $DATABRICKS_REPO -> run 01-clone-sibling-repo first." >&2
  exit 1
fi

for bin in git gh; do
  command -v "$bin" >/dev/null 2>&1 || { echo "$bin not on PATH -> run the 02-setup-local-env skill first." >&2; exit 1; }
done

cd "$DATABRICKS_REPO"

if ! gh auth status >/dev/null 2>&1; then
  echo "gh not authenticated -> run 'gh auth login' in your own terminal first." >&2
  exit 1
fi

echo "== Fetching origin/$BASE_BRANCH =="
git fetch origin "$BASE_BRANCH" --quiet

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
HAS_CHANGES="$(git status --porcelain)"

if [ -z "$HAS_CHANGES" ]; then
  if [ "$CURRENT_BRANCH" = "$BASE_BRANCH" ]; then
    echo "Error: working tree is clean and currently on $BASE_BRANCH -- nothing to branch off or" >&2
    echo "commit. Make your changes first, or check out an existing feature branch." >&2
    exit 1
  fi
  AHEAD="$(git rev-list --count "origin/$BASE_BRANCH..HEAD" 2>/dev/null || echo 0)"
  if [ "$AHEAD" = "0" ]; then
    echo "Nothing to commit, and '$CURRENT_BRANCH' has no commits ahead of origin/$BASE_BRANCH --" >&2
    echo "nothing to open a PR for." >&2
    exit 1
  fi
  echo "Working tree is clean; '$CURRENT_BRANCH' is $AHEAD commit(s) ahead of origin/$BASE_BRANCH."
  echo "Proceeding straight to push -- no new commit needed."
  BRANCH_NAME="$CURRENT_BRANCH"
else
  if [ "$CURRENT_BRANCH" = "$BASE_BRANCH" ]; then
    echo "== Creating branch $BRANCH_NAME (off origin/$BASE_BRANCH) =="
    git checkout -b "$BRANCH_NAME" "origin/$BASE_BRANCH"
  else
    echo "Already on branch '$CURRENT_BRANCH' (not $BASE_BRANCH) -- using it instead of creating $BRANCH_NAME."
    BRANCH_NAME="$CURRENT_BRANCH"
  fi

  if [ -z "$COMMIT_MESSAGE" ]; then
    echo "Error: there are uncommitted changes but no commit message was given." >&2
    exit 1
  fi

  echo
  echo "== Staging =="
  git add -A
  git status --short

  echo
  echo "== Committing =="
  git commit -m "$COMMIT_MESSAGE"
fi

echo
echo "== Pushing $BRANCH_NAME =="
git push -u origin "$BRANCH_NAME"

echo
echo "== Opening PR (base: $BASE_BRANCH) =="
REPO_SLUG="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
EXISTING_PR="$(gh pr list --repo "$REPO_SLUG" --head "$BRANCH_NAME" --json url -q '.[0].url' 2>/dev/null || true)"
if [ -n "$EXISTING_PR" ]; then
  echo "PR already exists for $BRANCH_NAME: $EXISTING_PR"
else
  gh pr create --repo "$REPO_SLUG" --base "$BASE_BRANCH" --head "$BRANCH_NAME" \
    --title "$PR_TITLE" --body "$PR_BODY"
fi

echo
echo "Done. terraform-plan.yml fires automatically for any infrastructure/** change in this PR --"
echo "check the PR's checks tab for the plan output. Merging (a separate, human decision) is what"
echo "triggers terraform-apply.yml."
