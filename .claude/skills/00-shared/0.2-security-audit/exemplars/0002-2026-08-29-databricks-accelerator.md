# Security audit — databricks + accelerator — 2026-08-29 (run 2)

**Score: 93/100 — Excellent** (`chaitu67/databricks`, public; `chaitu67/accelerator`, private)

Second run, same day as [`0001`](0001-2026-08-29-databricks-accelerator.md), after two of that
exemplar's HIGH findings were fixed directly (GitHub repo-settings API calls, not a PR) and
`databricks` PR #10 (the `acl_dev_analytics_*` groups/grants) merged in between.

## Actionable, not yet fixed

| Finding | Severity | Deduction |
|---|---|---|
| 12 Checkov checks still fail on both `root_storage` and `catalog_storage` S3 buckets (versioning, KMS, access logging, cross-region replication, lifecycle, event notifications). Unchanged from `0001` — one root cause, not exploitable (public access fully blocked on both). | MEDIUM | −5 |
| User's personal email (`datagaiinc@gmail.com`) still committed and publicly visible in `databricks` (`workspaces.auto.tfvars`, and now also `groups.auto.tfvars`). Unchanged from `0001`. | LOW | −2 |

**Total deductions: −7 → 93/100 (Excellent)**

## Fixed since 0001 (no longer deducted)

- **Secret scanning on `databricks`**: was disabled (HIGH, −10 in `0001`) → confirmed **enabled**
  (`security_and_analysis.secret_scanning.status`, re-checked via a fresh scan this run).
- **Dependabot alerts on `databricks`**: was disabled (HIGH, −10 in `0001`) → confirmed
  **enabled** (the alerts endpoint now returns `[]` instead of a "disabled" error).

## Operational note, not a security finding (not scored)

**Correcting a wrong assumption from `0001`'s follow-up discussion:** it was hypothesized that
merging PR #10 (which makes `datagaiinc@gmail.com` a member of `acl_dev_analytics_owner`,
`ALL_PRIVILEGES` on the `analytics` catalog) would incidentally fix the local user's inability to
`terraform plan` — specifically, reading `analytics-external-location`'s state. **Re-tested after
the merge: still fails with the same "does not have any non-BROWSE privileges" error.** This is
not a security weakness (it's the opposite — access is too *restrictive*, not too permissive), but
the earlier guess was wrong and shouldn't be repeated. Most likely real cause: Unity Catalog
treats **External Locations as a securable type independent of the Catalog** they back — a
catalog-level grant (even `ALL_PRIVILEGES`) doesn't cascade to the external location object itself,
which needs its own explicit grant or ownership change. Not fixed this run (wasn't asked); flagging
so the next audit (or the next person debugging this) doesn't re-assume the merge should have
fixed it.

## Checked and clean

- No hardcoded secrets/keys/tokens in tracked files in either repo (re-grepped both).
- Remote Terraform state bucket: still fully locked down (public access blocked, SSE-AES256,
  versioned) — unchanged.
- All GitHub Actions across all 3 `databricks` workflows still SHA-pinned — unchanged.
- Workflow `permissions:` blocks still minimally scoped per-job — unchanged.
- `pull_request` used throughout, never `pull_request_target` — unchanged.
- `modules/group` (merged via PR #10) confirmed introduced no AWS resources and needed no new
  CI-role IAM statement, as predicted in `0001`.
- `accelerator`: still no secrets, still zero GitHub Actions workflows.

## Accepted risk ledger

Carried forward from `0001`; re-confirmed this run, all unchanged:

- **CI service principal has Databricks `account_admin`.** *Status: unchanged.*
- **`databricks` is public; AWS OIDC trust scoped to `pull_request`/`environment:production`
  subjects.** *Status: unchanged.*
- **`production` GitHub Environment allows admin bypass, does not prevent self-review.**
  *Status: unchanged.*
- **`main` branch protection has `enforce_admins: false`.** *Status: unchanged.*
