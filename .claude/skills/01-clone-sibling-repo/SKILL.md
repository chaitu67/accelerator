---
name: 01-clone-sibling-repo
description: Clone the git repositories tracked in this skill's repos.txt list (or a repo the user explicitly names) so each lands as a sibling directory to the accelerator repo (same parent folder), not nested inside it. Use whenever the user asks to pull down, clone, sync, or fetch the sibling repos for accelerator to work against.
---

# Clone Sibling Repo

Clones repositories into the **parent** directory of this accelerator repo, so each checkout ends up next to `accelerator/` rather than inside it.

## Default repo list

`repos.txt` in this skill's directory is the source of truth for which repos to clone by default — one git URL per line, blank lines and `#` comments ignored. The user maintains this list over time (adding/removing lines); always read it fresh rather than assuming a prior conversation's contents.

- If the user asks to clone/sync/set up the sibling repos without naming one specifically, read `repos.txt` and process every entry in it. Do **not** ask the user for a repo link in this case — the list is the answer.
- If the user names a specific repo (URL, `org/repo`, or plain name) in their request, process that one instead, and if it's a new addition they want kept around, append it to `repos.txt` (as a full URL, deduped) so future runs pick it up automatically.

## Steps

For each repo to process:

1. Resolve the accelerator repo root by running `git rev-parse --show-toplevel` from inside this repo.
2. The clone target directory is the parent of that root. For example, if accelerator is at `/workspace/databricks-workshop/accelerator`, clones land in `/workspace/databricks-workshop/`.
3. Resolve what to clone:
   - A full git URL (https or ssh) — use as-is.
   - An `org/repo` shorthand — assume GitHub: `https://github.com/org/repo.git`.
   - A bare repo name with no org/host — ask the user which org/host it lives under. Don't guess.
4. Derive the target directory name from the repo name (strip a trailing `.git`). Check whether `<parent>/<repo-name>` already exists:
   - If it's already a git checkout of the same remote, skip cloning and tell the user it's already present. Only run `git -C <dir> fetch` if they asked to update it.
   - If it exists but isn't a matching checkout, stop and ask before doing anything — never delete or overwrite an existing sibling directory.
5. Run `git clone <resolved-url> <parent-dir>/<repo-name>`.
6. Report the resulting path back to the user.

When processing the full list, summarize all results at the end (cloned / already present / skipped) rather than reporting after each one.

## Constraints

- Never clone into an existing non-empty directory that isn't a matching git checkout.
- This skill only adds new sibling directories — never run destructive commands (rm, reset --hard, force-push) against the parent directory or its existing contents.
