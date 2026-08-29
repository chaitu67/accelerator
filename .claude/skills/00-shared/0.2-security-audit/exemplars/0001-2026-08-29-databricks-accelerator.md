# Security audit — databricks + accelerator — 2026-08-29

**Score: 73/100 — Fair** (`chaitu67/databricks`, public; `chaitu67/accelerator`, private)

This is the canonical first exemplar for `0.2-security-audit`, written up retroactively from a
manual review done earlier the same day (before this skill existed) and rescored against the
skill's rubric for consistency with future runs. One correction surfaced during that review,
worth restating here: the request that prompted it assumed both repos were public — only
`databricks` actually is; `accelerator` is private and has zero GitHub Actions workflows, so it
carries no CI/OIDC exposure at all. The findings below are almost entirely about `databricks`
as a result.

## Actionable, not yet fixed

| Finding | Severity | Deduction |
|---|---|---|
| Secret scanning disabled on `databricks` (public) — free GitHub feature, currently off | HIGH | −10 |
| Dependabot alerts disabled on `databricks` (public) — free, currently off | HIGH | −10 |
| 12 Checkov checks fail on both `root_storage` and `catalog_storage` S3 buckets: no versioning, no KMS encryption, no access logging, no cross-region replication, no lifecycle policy, no event notifications. One root cause (the shared module pattern), not exploitable today since public access is fully blocked on both, but replicated into the new catalog bucket rather than shrinking. | MEDIUM | −5 |
| User's personal email (`datagaiinc@gmail.com`) is committed in `workspaces.auto.tfvars`/`groups.auto.tfvars` and is publicly visible in `databricks`. Known since an earlier review; deprioritized, not yet fixed or explicitly accepted. | LOW | −2 |

**Total deductions: −27 → 73/100 (Fair)**

## Checked and clean

- No hardcoded secrets/keys/tokens in tracked files in either repo (grepped both for AWS key
  patterns, PEM headers, generic secret/token/password assignments).
- Remote Terraform state bucket (`databricks-tfstate-065790771695`): public access fully blocked,
  SSE-AES256 encrypted, versioning enabled.
- All GitHub Actions across all 3 `databricks` workflows are pinned to commit SHAs, not mutable
  tags (fixed in an earlier PR, still holds).
- Workflow `permissions:` blocks are scoped minimally per-job (`contents: read` plus only the
  specific write scope each job needs — `pull-requests: write` for comment-posting jobs,
  `id-token: write` for OIDC jobs) — no workflow requests broader access than it uses.
- `pull_request` is used throughout, never the dangerous `pull_request_target`.
- Checkov's CI scan passed clean (no *new* misconfiguration) on the two most recent PRs.
- This session's new `modules/group` (account-level Databricks groups + grants) introduces zero
  AWS resources, so it needed — and correctly has — no new CI-role IAM statement, unlike the
  catalog module's earlier miss (since fixed).
- `accelerator` (private): no secrets found, no GitHub Actions workflows at all.

## Accepted risk ledger

Carried forward as explicitly accepted by the user; not scored. Each should be re-confirmed as
still accurate on the next run, not silently assumed unchanged forever.

- **CI service principal has Databricks `account_admin`.** Full account takeover risk if the
  pipeline is ever compromised. Accepted deliberately, with the user's confirmation, when the
  workspace was first created. *Status: unchanged.*
- **`databricks` is public; AWS OIDC trust allows any branch/PR in the repo to assume the CI
  role** (scoped to `pull_request`/`environment:production` subjects specifically, tightened from
  a full wildcard in an earlier PR). The real backstop is GitHub's own block on secrets for
  fork-triggered `pull_request` runs plus the first-time-contributor approval gate — a process
  control, not a technical one enforced by this repo's config. *Status: unchanged.*
- **`production` GitHub Environment allows admin bypass and does not prevent self-review.** For a
  one-person repo (the reviewer is the merger) this gives no real separation of duties today, just
  an audit trail. *Status: unchanged.*
- **`main` branch protection has `enforce_admins: false`.** The repo owner can push directly to
  `main`, bypassing PR review, if they choose to. *Status: unchanged.*
