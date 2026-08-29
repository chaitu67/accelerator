# 00-shared skills

Skills in this group are **generic and repo-agnostic** — unlike `01`–`05`, they have no
dependency on that sequence (cloning the sibling repo, local tooling, Terraform scaffolding,
CI/CD setup, or a deployed workspace) and aren't specific to Databricks/Terraform content.
Numbered `00` (before `01`) precisely to signal that: nothing here waits on anything else in
this project, and everything here could run standalone from the very first day of a repo's
life, or be dropped into a completely different project unchanged.

## Skills in this group

- `0.1-pr-security-scan` — scaffolds a GitHub Actions workflow that runs a security scan
  (secrets, IaC misconfiguration, dependency vulnerabilities) on every pull request, in any repo,
  regardless of what changed. Posts results as a PR comment; fails the check only on
  CRITICAL/HIGH severity findings.

## Convention

- A new skill in this group gets the next `0.N` number and its own subdirectory:
  `00-shared/0.N-<name>/`.
- Each still needs its own `SKILL.md` per the usual skill format — this README is an index for
  the group, not a skill itself.
- Before adding something here, double-check it really has no dependency on `01`–`05` and isn't
  Databricks/Terraform-specific — if it needs the sibling repo cloned, local tooling installed,
  or a deployed workspace, it belongs in one of the numbered groups instead, not here.
