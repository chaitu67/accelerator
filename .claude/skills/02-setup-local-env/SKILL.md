---
name: 02-setup-local-env
description: Set up (or refresh) the accelerator project's local dev environment - a Python venv at accelerator/.venv with the project's pip packages, plus Terraform, AWS CLI, Databricks CLI, and GitHub CLI via Homebrew. Use whenever the user asks to set up, install, or refresh the local environment/toolchain for accelerator, or before running Python/terraform/aws/databricks/gh commands in this project.
---

# Setup Local Env

Manages one local environment for the accelerator repo: a project-scoped Python venv plus the CLI tools this project's workflows depend on (Terraform, AWS CLI, Databricks CLI). Designed to grow — adding a new pip package or CLI tool later is a small, isolated edit, not a rewrite.

## What it manages

- **Python venv** at `<accelerator repo root>/.venv`, packages from `requirements.txt` in this skill's directory.
- **CLI tools** via Homebrew: `terraform`, `aws` (awscli), `databricks`, `gh` (GitHub CLI). Installed only if missing; existing installs are left alone.

## Running it

Run `setup.sh` in this skill's directory. It is idempotent — safe to re-run any time to sync the environment after `requirements.txt` or the tool list changes:

```
bash .claude/skills/02-setup-local-env/setup.sh
```

It resolves the accelerator repo root itself (via `git rev-parse --show-toplevel`), so it works regardless of the caller's cwd.

If Homebrew isn't installed, the script sets up the Python venv fully, then stops and tells the user to install Homebrew manually (https://brew.sh) rather than running the Homebrew installer itself — that installer needs sudo and touches the system outside this project, which isn't a step to take unprompted. Re-running the skill after Homebrew is installed picks up the CLI tools.

## Tell the user to do this once, in their own terminal

These don't happen inside the skill's Bash calls (which run in an isolated shell), so after the skill reports success, tell the user to check for them in their actual terminal:

- **`brew`/`terraform`/`aws`/`databricks` show "command not found" even though the skill just installed them:** a fresh Homebrew install doesn't add itself to `PATH` for future shells on its own — it needs `eval "$(/opt/homebrew/bin/brew shellenv)"` in `~/.zprofile` (Apple Silicon path shown; Intel Macs use `/usr/local/bin/brew`). Have the user add that line if it's missing, then open a new terminal (a plain `source ~/.zprofile` in the current one also works).
- **Plain `python` doesn't work:** macOS ships no `python` command, only `python3` — this is normal, not a broken install. The venv only provides a `python` alias while activated (`source .venv/bin/activate`); otherwise use `python3` or the absolute-path binaries below.

## Using the environment afterward

Bash tool calls don't persist shell state (like an activated venv) between invocations, so **always invoke the venv's binaries by absolute path** rather than relying on `source .venv/bin/activate` carrying over:

- `<repo_root>/.venv/bin/python`
- `<repo_root>/.venv/bin/pip`

The Homebrew-installed CLI tools (`terraform`, `aws`, `databricks`) are on the normal system `PATH` once installed, so they don't need this treatment.

## Growing it

- **New pip package:** add a line to `requirements.txt`, then re-run `setup.sh`.
- **New CLI tool:** add an `ensure_brew_tool <binary> <brew-formula> [tap]` line in `setup.sh` next to the existing ones, then re-run it.

## Constraints

- Never installs Homebrew itself — only tells the user to.
- Never deletes or recreates an existing `.venv` — reuses it and syncs packages into it.
- Never runs `brew` operations beyond installing the specific formulas listed (no `brew upgrade --all`, no touching unrelated casks/formulas).
