# accelerator

Skills, agents, and workflow that automate building out a Databricks/Terraform platform via
Claude Code. This repo holds the automation itself; the infrastructure it manages lives in a
sibling `databricks` repo, cloned alongside this one via `01-clone-sibling-repo`.

## How skills are organized

Numbered groups under `.claude/skills/`, each a `SKILL.md` (or nested `N.M-*/SKILL.md`) Claude
Code skill. The number generally encodes a dependency order — a skill in group `N` assumes group
`N-1`'s prerequisites are already met — except `00-shared`, which has no dependency on the
sequence at all.

| Group | What it does |
|---|---|
| [00-shared](.claude/skills/00-shared/README.md) | Generic, repo-agnostic skills with no dependency on 01–09: PR security scanning, scored security audits. |
| [01-clone-sibling-repo](.claude/skills/01-clone-sibling-repo/SKILL.md) | Clones this repo's tracked sibling repos (e.g. `databricks`) so they land next to `accelerator/`. |
| [02-setup-local-env](.claude/skills/02-setup-local-env/SKILL.md) | Sets up/refreshes the local dev environment: a project-scoped Python venv plus Terraform, AWS CLI, Databricks CLI, GitHub CLI. |
| [03-terraform-setup](.claude/skills/03-terraform-setup/README.md) | Scaffolds the Terraform project inside the sibling `databricks` repo and checks prerequisites. |
| [04-github-cicd](.claude/skills/04-github-cicd/README.md) | Wires up GitHub Actions CI/CD for that Terraform project — OIDC, remote backend, workflows, PR flow. |
| [05-databricks-terraform-deployment](.claude/skills/05-databricks-terraform-deployment/README.md) | Creates real, billed Databricks/AWS infrastructure: workspaces, Unity Catalog catalogs, catalog access, volumes. |
| [06-organization-setup](.claude/skills/06-organization-setup/README.md) | Maps an entire organization onto Databricks/Unity Catalog primitives and rolls it out end to end (discover → pattern → plan → deploy). Start with `6.0-manage-organization` if unsure which skill applies — it also routes into 07/08/09. |
| [07-business-unit-setup](.claude/skills/07-business-unit-setup/README.md) | Day-two: adds one new business unit/department (workspace only) to an org that already exists. |
| [08-lob-setup](.claude/skills/08-lob-setup/README.md) | Day-two: adds one new line-of-business catalog to a unit that already has a running workspace. |
| [09-environment-setup](.claude/skills/09-environment-setup/README.md) | Day-two: promotes a business unit to a new environment tier (e.g. `dev` → `stg`). |

Every group's own `README.md` (or, for single-skill groups, the `SKILL.md` itself) explains its
scope and why it's numbered where it is in more depth than this table.

## Agents

- [repo-fetcher](.claude/agents/repo-fetcher.md) — clones the sibling repos tracked by
  `01-clone-sibling-repo` (plus any the user names) so they sit next to `accelerator/`.

## New user guide

You don't need to know any skill names to use this — describe what you want in plain language to
Claude Code and it routes to the right skill. The names below are shown so you can also invoke one
directly, and so you know what order things depend on.

Every skill that touches real infrastructure opens a reviewed PR and shows you a `terraform plan`
before anything is applied — nothing here pushes straight to prod on its own.

### Step-by-step walkthrough (first-time setup)

1. **Clone the sibling repo.** Say *"clone the sibling repos"*. Runs
   [01-clone-sibling-repo](.claude/skills/01-clone-sibling-repo/SKILL.md) — clones the repos listed
   in its `repos.txt` (by default, the `databricks` repo that holds your actual Terraform project)
   so they sit next to this `accelerator/` directory, not nested inside it.

2. **Set up your local environment.** Say *"set up my local environment"*. Runs
   [02-setup-local-env](.claude/skills/02-setup-local-env/SKILL.md) — creates a Python venv at
   `accelerator/.venv` and installs Terraform, the AWS CLI, the Databricks CLI, and the GitHub CLI
   via Homebrew.

3. **Scaffold the Terraform project.** Say *"scaffold the Terraform project"* or *"set up
   infrastructure as code for Databricks"*. Runs
   [03-terraform-setup](.claude/skills/03-terraform-setup/README.md) — checks prerequisites, then
   creates an `infrastructure/` Terraform project inside the sibling `databricks` repo.

4. **Wire up CI/CD.** Say *"set up CI/CD for Databricks Terraform"*. Runs the
   [04-github-cicd](.claude/skills/04-github-cicd/README.md) group in order: checks prerequisites,
   sets up the remote Terraform backend, configures GitHub OIDC (so Actions can authenticate to
   AWS without long-lived secrets), creates the workflow files, then opens it all as a PR.

5. **Deploy your first real infrastructure.** Say *"create a Databricks workspace"* to run
   [5.1-create-workspace](.claude/skills/05-databricks-terraform-deployment/5.1-create-workspace/SKILL.md).
   From there: *"create a Unity Catalog catalog"* (`5.2`), *"manage catalog access"* (`5.3`),
   *"create a volume"* (`5.4`) — see
   [05-databricks-terraform-deployment](.claude/skills/05-databricks-terraform-deployment/README.md).

6. **(Multiple teams) Model your whole organization instead of hand-running step 5 per team.**
   Describe your org structure and say *"set up my organization in Databricks"*. Start with
   [6.0-manage-organization](.claude/skills/06-organization-setup/6.0-manage-organization/SKILL.md)
   — it inspects what's already in the repo and routes through discovery, pattern mapping,
   deployment planning, and rollout (`6.1`–`6.4`) for you.

7. **(Day two) Grow what's already deployed.** Once an org exists, `6.0-manage-organization` also
   routes these for you:
   - *"add a new business unit"* → [07-business-unit-setup](.claude/skills/07-business-unit-setup/README.md)
   - *"add a new line of business / catalog"* → [08-lob-setup](.claude/skills/08-lob-setup/README.md)
   - *"promote this unit to staging/prod"* → [09-environment-setup](.claude/skills/09-environment-setup/README.md)

8. **(Anytime, optional) Add security scanning.** These don't depend on any step above and work in
   any repo: *"add a PR security scan"*
   ([0.1-pr-security-scan](.claude/skills/00-shared/0.1-pr-security-scan/SKILL.md)) or *"run a
   security audit"* ([0.2-security-audit](.claude/skills/00-shared/0.2-security-audit/SKILL.md)).
