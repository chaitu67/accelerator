---
name: 4.5-open-terraform-pr
description: Commit uncommitted changes in the databricks repo to a new branch, push it, and open a PR against main -- so terraform-plan.yml runs on the PR (giving reviewers the plan output) instead of pushing straight to main. Use whenever there are local changes (e.g. from 5.1-create-workspace's implement.sh, or any edit under infrastructure/) ready to submit through the pipeline, or when the user asks to commit/push/open a PR for Databricks Terraform changes.
---

# Open Terraform PR (databricks repo)

Fifth skill in the `04-github-cicd` group — see [../README.md](../README.md). Where `4.4`
scaffolds the workflow files themselves, this skill is how changes actually flow *through* them
day to day: branch → commit → push → PR, rather than a direct push to `main`. This matters now
that `4.4`/`4.3` set up two review gates (branch protection requiring a PR + approval,
`production` environment requiring approval before apply) — pushing straight to `main` bypasses
the PR gate entirely for anyone with admin rights, which defeats the point of having it.

## Before starting

Run `4.1-check-cicd-prerequisites` first (or confirm it already passed) — this skill assumes
the pipeline it's submitting changes into already exists.

## Gather two details first

Ask the user (or infer from context — e.g. what `5.1-create-workspace`'s `implement.sh` just
scaffolded) rather than guessing generically:

- **A short description of the change** — used to derive the branch name (e.g.
  `infra/add-workspace-resources`) and as the basis for the commit message and PR title. Don't
  just write "update files" — say what actually changed and why, same as any other commit
  message.
- **Whether this is truly ready for review**, or still a work in progress the user wants to keep
  local for now — this skill pushes and opens a PR immediately, it doesn't stage a "draft nobody
  sees yet."

## Running it

```
bash .claude/skills/04-github-cicd/4.5-open-terraform-pr/open-pr.sh <branch-name> <commit-message> <pr-title> [pr-body] [base-branch]
```

- If the working tree has uncommitted changes: creates `<branch-name>` off `<base-branch>`
  (default `main`) — or reuses the current branch as-is if already off `main` — stages
  everything (`git add -A`; `.gitignore` already keeps `terraform.tfstate`/`terraform.tfvars`
  out, confirmed in this project), and commits with `<commit-message>`.
- If the working tree is already clean but the current branch has commits ahead of
  `origin/<base-branch>` that haven't been pushed: skips straight to pushing them (no new commit
  needed) — `<commit-message>` can be empty in this case.
- Pushes the branch and opens a PR via `gh pr create --base <base-branch> --head <branch-name>`.
  If a PR already exists for that branch, reports its URL instead of creating a duplicate.
- Prints the PR URL. `terraform-plan.yml` fires automatically once the PR exists (any change
  under `infrastructure/**`) — check back on that run, don't assume the plan succeeded.

## After opening the PR

This skill's job ends at "PR opened." Merging is a separate, human decision — after the PR's
plan comment looks right and it has its required approval, the user merges it themselves (in
the GitHub UI, or `gh pr merge` if they ask for that explicitly — not something this skill does
on its own). Merging is what triggers `terraform-apply.yml`.

## Constraints

- Never pushes directly to `main` (or whatever `base-branch` is) — always a new/existing
  feature branch, always through a PR.
- Never merges, approves, or force-pushes a PR itself — opening it is the full extent of this
  skill; review and merge are always a human action.
- Never commits with a generic placeholder message ("wip", "update") — the commit message and
  PR title should describe the actual change, gathered from the user/context first.
- Relies on `.gitignore` (already in place in `infrastructure/`) to keep `terraform.tfstate`,
  `terraform.tfstate.backup`, and `terraform.tfvars` out of what gets committed — `git add -A`
  is safe here because of that, not despite it. If `.gitignore` is ever missing or changed,
  re-check before trusting a blanket `git add -A`.
