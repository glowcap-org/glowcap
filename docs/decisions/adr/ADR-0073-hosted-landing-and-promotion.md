---
id: ADR-0073
status: accepted
date: 2026-10-29
tags: ["workflow", "publication", "provenance"]
decision: "dev is the default branch every change lands on, a pull request lands by squash merge, a workflow fast-forwards main to each dev commit whose push run passed, and a release is a maintainer-signed tag on main."
supersedes: []
superseded_by: []
amends: [ADR-0067]
amended_by: []
---

# ADR-0073 Hosted landing and promotion

## Context

[ADR-0067](ADR-0067-evidence-bearing-integration.md) made the worktree
integrator the only writer of `dev` and left promotion to `main` as a manual
fast-forward. Once the repository was public, three costs showed up. GitHub
sends contributor pull requests, Dependabot security updates, code scanning,
and scheduled runs to the default branch. With `main` as the default, those
landed where no change can, because `main` accepts only a fast-forward from
`dev`. Pull requests could not use the merge button, so each accepted one was
re-landed by hand and closed unmerged. Promotion was a step with no
decision in it: `main` only ever took the newest `dev` commit whose push run
passed, and the site waited on that step.

## Decision

- `dev` is the default branch. Contributions, Dependabot version and security
  updates, code scanning, and nightly runs all meet it.
- `dev` takes one signed commit per change in a linear history. A pull request
  lands by **Squash and merge** pinned to the reviewed head. GitHub signs the
  squash commit, keeps the contributor as its author, and closes the pull
  request as merged. A worktree branch still lands through the integrator.
- `main` is the newest `dev` commit whose push run of `check` passed. The
  [promote workflow](../../../.github/workflows/promote.yml) fast-forwards it
  after that run succeeds, and the push deploys the site. Nobody pushes `main`
  by hand. The workflow acts as an organization-owned GitHub App holding
  Contents and Workflows write on this repository, because the workflow token
  may not move a branch across workflow-file changes. The main ruleset is
  unchanged and refuses the app's move unless it is a signed, checked
  fast-forward.
- A release is a maintainer-signed `v*` tag on a `main` commit. The tag is the
  maintainer's decision point, and `release.yml` still requires the tagged
  commit's successful check.

The rest of ADR-0067 holds: the commit a check ran on is the commit `main`
publishes, and evidence records stay attached to it.

## Alternatives and consequences

Trunk development on `main` behind a merge queue also tests the exact commit it
lands, but serializes every change behind a full run of about an hour and
charges a full run per change. `dev` batches whatever landed while the
previous run ran, and only the newest commit's run finishes. Keeping `main` as
the default branch would leave security updates and contributions aimed at a
branch that cannot take them. Keeping promotion manual would keep a step that
chose nothing.

The repository page and a default clone show `dev`, which can be red between
runs. The site, its source links, and releases come from `main`. A
GitHub-signed squash commit says GitHub made it for an account with write
access, which is weaker than the maintainer's own key. The pull request records
who reviewed and merged it. A second maintainer, or a merge queue whose cost no
longer scales with run length, would justify revisiting this.

## Evidence

`ci/test/workflow_test.py` holds the promote workflow to a successful push run
on `dev` from this repository, no workflow-token permissions, the app token's
two permissions, and no checkout. It runs the job's script against a stub API:
an ahead commit fast-forwards `main`, a commit `main` already contains moves
nothing, and diverged history or an API failure stops before any write. None
of this shows the hosted ruleset accepting the app's push or that push
deploying the site. The first promotion after this record lands is that proof.
