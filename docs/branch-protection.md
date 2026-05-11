# Branch Protection & Required CI

This document describes the branch-protection / ruleset configuration that should be applied to `main` to enforce the CI hardening that lives in `.github/workflows/`.

> Branch protection is a repository **settings** concern. It cannot be enforced purely from source code. A repository admin must apply the configuration below in **Settings -> Rules -> Rulesets** (or **Settings -> Branches -> Branch protection rules** for the classic UI).

## Required status checks for `main`

Add the following GitHub Actions jobs as **required status checks** before a PR can be merged into `main`. Names must match the `name:` field on each workflow job exactly.

| Workflow file                         | Job name (required check)         |
| ------------------------------------- | --------------------------------- |
| `.github/workflows/ci.yml`            | `test`                            |
| `.github/workflows/lint.yml`          | `Swift format check`              |
| `.github/workflows/lint.yml`          | `Python lint (ruff)`              |
| `.github/workflows/lint.yml`          | `YAML lint`                       |
| `.github/workflows/coverage.yml`      | `Swift test coverage`             |
| `.github/workflows/dependency-review.yml` | `Dependency review`           |
| `.github/workflows/codeql.yml`        | `Analyze (python)`                |
| `.github/workflows/codeql.yml`        | `Analyze (javascript)`            |

## Recommended ruleset settings

In **Settings -> Rules -> Rulesets -> New branch ruleset**:

- **Name**: `main-protection`
- **Enforcement status**: Active
- **Target branches**: Include default branch (`main`)
- **Bypass list**: empty (or restricted to repo admins for emergencies only)
- **Rules**:
  - Restrict deletions
  - Block force pushes
  - Require a pull request before merging
    - Required approvals: 1 (or more)
    - Dismiss stale pull request approvals when new commits are pushed
    - Require review from Code Owners (if `CODEOWNERS` file present)
    - Require approval of the most recent reviewable push
  - Require status checks to pass
    - Require branches to be up to date before merging
    - Required checks: the table above
  - Require signed commits (optional but recommended)
  - Require linear history (optional)
  - Require deployments to succeed (skip unless using environments)

## Importing a starter ruleset

A starter ruleset JSON lives at `.github/rulesets/main-protection.json`. Import it via **Settings -> Rules -> Rulesets -> ... -> Import a ruleset**. Review and adjust before activating.

## Notes on enforcement

- The status-check **name** GitHub sees is the workflow job `name:`. If a `name:` field is missing, GitHub falls back to the job key. Use the table above as the source of truth.
- Rulesets supersede classic branch protection when both exist. Prefer rulesets.
- Required checks only block merge after they have run at least once on the target branch. After adding required checks, open a small dummy PR to seed them.
- Dependabot PRs need the same checks; ensure secrets needed by required workflows are exposed to `pull_request` events from forks only via `pull_request_target` patterns *carefully* (this repo currently does not).
