---
name: 0.2-security-audit
description: Run a security audit of a target repo (GitHub repo settings, hardcoded secrets, IaC misconfiguration, GitHub Actions hygiene, AWS S3 hardening where applicable) and score the result 0-100 against a fixed severity-weighted rubric. Repo-agnostic and works standalone in any repo, on-demand or on a recurring schedule. Every run's report is saved as a new dated exemplar in exemplars/, and the exemplars are themselves the style guide for how to write the next report -- read the most recent one before writing a new one. Use when the user asks for a security scan/audit/review, asks "are there vulnerabilities," or wants a recurring/scheduled security check.
---

# Security Audit (any repo)

Part of `00-shared` — see [../README.md](../README.md): this is repo-agnostic, no dependency on
`01`–`05`. It generalizes the manual security review already done for `databricks`/`accelerator`
on 2026-08-29 (see [`exemplars/0001-2026-08-29-databricks-accelerator.md`](exemplars/0001-2026-08-29-databricks-accelerator.md),
the canonical first exemplar) into a repeatable, scored procedure.

## What this is (and isn't)

`0.1-pr-security-scan` scaffolds *CI* that runs Checkov on every PR diff and gates merges on a
curated critical-check list. This skill is different: an *on-demand or scheduled* deep audit of a
whole repo's current state — GitHub platform settings, secrets, IaC, Actions hygiene, cloud
hardening — synthesized into one report with one score. It complements `0.1`, doesn't replace it;
if `0.1` isn't set up in the target repo yet, note that as a finding rather than silently skipping
CI-related checks.

## Running it

```
bash .claude/skills/00-shared/0.2-security-audit/scan.sh [path-to-target-repo]
```

Defaults to the current directory. Prints raw, unscored signal to stdout in labelled sections —
repo settings (visibility, secret scanning/Dependabot/push-protection status, branch protection,
environment protection rules), a hardcoded-secrets grep, GitHub Actions workflow
permissions/pinning/trigger-type audit, Terraform/IaC presence (running `checkov` locally if
installed, else falling back to the most recent CI scan's PR comment if `gh`/a PR exists), and AWS
S3 bucket hardening (public-access block, encryption, versioning) for any bucket name it can find
literally in the target repo's Terraform/tfvars. Every section degrades gracefully to "not
applicable"/"skipped" rather than erroring when a signal doesn't apply (no Terraform, no GitHub
Actions, `gh`/`aws`/`checkov` not installed, insufficient token scope) — this script never fails
the whole run over one inapplicable check.

**This script only gathers; it never scores or writes prose.** Read its full output, then apply
the rubric below yourself — severity judgment (is this exploitable now, or a defense-in-depth gap;
is this a new problem, or a risk the user already explicitly accepted) needs the same reasoning a
human reviewer would apply, not a mechanical rule.

## Before writing a new report

Read the most recent file in `exemplars/` (sorted by filename — they're numbered) for two things:
1. **Style** — section headers, tone, level of detail. Match it; don't reinvent the format each
   run.
2. **The accepted-risk ledger** — risks a user has already explicitly signed off on (e.g. "CI
   service principal has account_admin, confirmed deliberate"). Carry these forward as a distinct
   section, unscored, rather than re-deducting for them every run — a risk stays "accepted," not
   "new," until something about it actually changes (new evidence it materialized, the user
   revokes their acceptance, or the underlying config drifted since it was accepted). Note whether
   each ledger entry still holds as described, or has changed since — say so explicitly either way,
   don't just carry it forward silently.

## Scoring rubric

Start at 100, floor at 0. For every **new or still-open, not-yet-accepted** finding, deduct once
per distinct root cause (not once per affected resource — twelve identical Checkov findings across
two S3 buckets is one root cause, one deduction, noted as affecting N resources):

| Severity | Deduction | What qualifies |
|---|---|---|
| CRITICAL | −25 | Currently exploitable: a real hardcoded live credential, a resource/permission openly exposed with no compensating control, an auth bypass. |
| HIGH | −10 | Real risk, not immediately exploitable: a free/available hardening control left off on a public-facing repo (secret scanning, Dependabot), overly broad IAM/OIDC trust, disabled required review on a shared branch. |
| MEDIUM | −5 | Real gap, low immediate risk, mostly defense-in-depth/audit-trail: missing S3 versioning/encryption/access-logging on an already access-blocked bucket, a Checkov check failing outside the target's own curated gate list. |
| LOW | −2 | Cosmetic, process-only, or already-mitigated-elsewhere gaps. |

Map the final number to a band for the headline: **90–100 Excellent, 75–89 Good, 60–74 Fair,
40–59 Poor, <40 Critical.** Show the arithmetic in the report (which findings, which deductions)
— never just assert a number; the reader should be able to recompute it from the findings list.

## Report format

Match `exemplars/0001-...`'s structure:
1. One-line headline: score, band, target repo(s), date.
2. **Actionable, not yet fixed** — new or still-open findings, with the deduction each contributed.
3. **Checked and clean** — things explicitly verified with no gap found (don't skip this section;
   a review that only lists problems reads as less thorough than one that shows what was checked).
4. **Accepted risk ledger** — carried forward from the prior exemplar, each flagged as unchanged
   or changed-since-acceptance; unscored.
5. Total score with the running arithmetic.

## After writing a report

Save it as `exemplars/<NNNN>-<YYYY-MM-DD>-<repo-slug-or-slugs>.md`, incrementing `NNNN` from the
highest existing file. This is not optional bookkeeping — the exemplar library is what keeps
future runs consistent in style and honest about score trend (a user should be able to ask "did
this get better or worse since last time" and get a real answer from the file history, not a
guess). Never overwrite or edit a past exemplar; each run adds a new one.

## Scheduling a recurring run

This skill has no built-in cron of its own — wire it into the existing scheduling mechanisms
rather than inventing a new one:
- **Within one long-lived session:** the `loop` skill (`/loop <interval> "run the 0.2-security-audit
  skill against <repo>"`).
- **Unattended, across sessions:** the `schedule` skill, to create a recurring cloud agent on a
  cron expression, with a prompt that names the target repo(s) and points at this skill.

Setting up an actual recurring schedule is a standing, ongoing action (a new resource that keeps
running after this conversation ends) — confirm the interval and target repo(s) with the user
explicitly before creating one; don't infer a cadence and set it up unprompted.

## Constraints

- Never invents a score without showing which findings produced which deductions.
- Never re-deducts for a ledger-accepted risk unless something about it has actually changed —
  say explicitly whether it's unchanged or changed, don't silently drop it either way.
- Never skips the "checked and clean" section — an audit that only lists problems is indistinguishable
  from one that didn't check the rest.
- Never edits or deletes a past exemplar — the history is the point.
- Never sets up a recurring schedule without the user explicitly confirming the interval and
  target(s) first.
- Degrades gracefully per-check (missing `gh`/`aws`/`checkov`, insufficient token scope, no
  Terraform, no GitHub Actions) rather than failing the whole run — this must work standalone in
  any repo, including ones with none of those things.
