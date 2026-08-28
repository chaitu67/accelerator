# 03-terraform-setup skills

Skills numbered `3.x` in this group set up the Terraform *project* inside the sibling
`databricks` repo (cloned via [01-clone-sibling-repo](../01-clone-sibling-repo/SKILL.md)) and
confirm the environment can actually run it. This is distinct from `01`/`02`, which manage the
`accelerator` repo's own tooling and local environment.

This group deliberately stops at "the project exists and I can run terraform against it" — it
does **not** include creating any real Databricks/AWS infrastructure. That's
[05-databricks-terraform-deployment](../05-databricks-terraform-deployment/README.md), run
after [04-github-cicd](../04-github-cicd/README.md) — see that group's README for why the order
is scaffold → CI/CD → first real deployment, not scaffold → deployment → CI/CD.

## Skills in this group

- `3.1-scaffold-infrastructure` — creates the `infrastructure/` Terraform project inside
  `databricks/` (or reuses it if it already exists).
- `3.2-check-prerequisites` — read-only audit of everything needed to actually run
  `terraform init/plan/apply` (repo, scaffold, CLI tools, AWS/Databricks authentication). If
  the AWS or Databricks check fails, drills into its matching sub-skill:
  - `3.2.1-authenticate-aws` — gets `aws sts get-caller-identity` passing.
  - `3.2.2-authenticate-databricks` — gets `databricks current-user me` passing.

## Convention

- A new skill in this group gets the next `3.N` number and its own subdirectory:
  `03-terraform-setup/3.N-<name>/`.
- If a `3.N` skill needs its own finer-grained steps, they nest one level deeper as
  `3.N.M-<name>/` subdirectories inside it (e.g. `3.2-check-prerequisites/3.2.1-<name>/`) —
  same rule, just one level down.
- Each still needs its own `SKILL.md` per the usual skill format — this README is an index
  for the group, not a skill itself.
- Skills that create real, billed Databricks/AWS infrastructure belong in
  `05-databricks-terraform-deployment`, not here — this group is scaffold-and-audit only.
