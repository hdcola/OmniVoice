# AGENTS.md

This document defines the repository workflow rules for all contributors and coding agents working in this project.

## 1. Core Principles

- Never commit directly to `main`.
- All changes must go through a feature or fix branch, followed by review (PR), before landing on `main`.
- All user-facing changes must be recorded in `CHANGELOG.md`.

## 2. Branch Workflow

### For bug fixes

Use a `fixbug/` branch:

```bash
git checkout main
git pull origin main
git checkout -b fixbug/short-description
```

### For features

Use a `feature/` branch:

```bash
git checkout main
git pull origin main
git checkout -b feature/short-description
```

## 3. Working Rules

- If you accidentally modify files while on `main`, do not commit there.
- Create the correct `fixbug/...` or `feature/...` branch immediately and continue work on that branch.
- Only stage files related to the task.
- Do not blindly run `git add .` — review `git status` before staging.
- Do not use `git commit --amend` unless explicitly requested.
- Do not use force push unless explicitly requested.

## 4. Required Validation Before Commit

Before committing, run the relevant validation (build/lint/tests) for the scope of your change. Use judgment and run the smallest sufficient validation set for the change.

## 5. Commit Workflow

Example safe workflow:

```bash
git status
git add path/to/changed/file
git commit -m "fix(scope): short description"
```

Prefer conventional commit style:

- `feat(scope): ...`
- `fix(scope): ...`
- `docs(scope): ...`
- `refactor(scope): ...`
- `test(scope): ...`
- `chore(scope): ...`

## 6. Pull Request Workflow

After validation and commit:

```bash
git push -u origin fixbug/short-description
```

Then open a pull request for review.

Recommended PR expectations:

- clear title
- concise summary
- affected files or modules
- validation performed
- risks or follow-up notes

## 7. CHANGELOG Workflow

This repository uses a root-level `CHANGELOG.md` and follows Keep a Changelog style.

### Rules

- Every merged PR should add an entry under `## [Unreleased]`.
- Add entries for:
  - features
  - bug fixes
  - refactors affecting behavior
  - dependency changes
  - test changes
  - documentation changes
  - build or CI workflow changes
- If no PR number exists yet, use a short commit hash reference.
- Once the PR exists, prefer the PR reference.

### Recommended sections

Under `## [Unreleased]`, use these sections as needed:

- `### Added`
- `### Changed`
- `### Fixed`
- `### Dependencies`
- `### Documentation`
- `### Tests`
- `### Removed`

### Entry format

Use one line per change, concise and user-focused.

Examples:

```markdown
- fix(audio): correct sample-rate mismatch in the recording pipeline (#12)
- feat(ui): add live transcript panel (#14)
- docs(repo): add repository workflow guidance (31f106a)
```

## 8. When to Create CHANGELOG.md

If `CHANGELOG.md` does not exist yet, create it at the repository root before merging user-facing changes.

Recommended initial structure:

```markdown
# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog.

## [Unreleased]

### Added

### Changed

### Fixed

### Dependencies

### Documentation

### Tests
```

## 9. Scope of This File

This file exists to make the expected repository workflow explicit for both humans and automated coding agents.

When in doubt:

1. create a non-main branch
2. make the smallest safe change
3. validate the change
4. update `CHANGELOG.md`
5. open a PR (Section 6)

## 10. Releasing

Cutting a version (version bump, changelog cut, DMG build, tag, GitHub
Release, Homebrew cask) is described in `Docs/RELEASING.md`. A release cut is
a `chore/release-X.Y.Z` branch and a PR like any other change.
