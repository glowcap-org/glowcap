---
type: static
description: Reviewing and integrating changes locally, then promoting checked commits for publication.
sources:
  - resource: /.github/workflows/check.yml
  - resource: /.github/workflows/pages.yml
  - resource: /.github/workflows/release.yml
  - resource: /tools/check/publication-integration-test.sh
  - resource: /tools/check/require-main-check.py
  - resource: /.github/rulesets/
---

# Maintaining glowcap

The maintainer reviews changes into `dev`. Local work reaches `dev` through
the worktree integrator. Hosted pull requests and protected promotion to
`main`, the publication branch, require GitHub checks and repository protection
to be available. The [roadmap](roadmap.md#open-obligations-from-retired-plans)
owns activation and outstanding hosted verification.

## Integrating locally

When hosted review is unavailable, review the local diff and run the checks
for the changed area before integrating. Record the commands, results, and
untested paths in the handoff. Local results do not establish that hosted
checks or branch protection work.

Commit the reviewed change on its worktree branch. From that clean worktree,
synchronize with the shared branches using the worktree integrator.
Synchronization can change the diff. Review it and rerun affected checks if
it does, then integrate.

The integrator advances local `dev` without checking it out or moving another
worktree. With authorization to publish accepted changes, run:

```sh
git push origin refs/heads/dev:refs/heads/dev
```

A rejected push needs reconciliation through the synchronization procedure
below. Never force `dev`. Local integration does not publish to `main`, deploy
Pages, or create a release.

## Reviewing a contribution

Establish the problem and the behavior the patch changes. Read its tests and
run the focused check for the affected area. Check protocol claims against
their outside authority. Inspect executable changes to CI, dependencies,
permissions, and release tooling before approving a fork workflow to run.

Request changes for correctness, security, necessary coverage, or a documented
constraint. Explain why and mark optional suggestions. Keep unrelated cleanup
separate. Preserve contributor authorship. Close out-of-scope work with a reason.

Review the latest diff and check results after revisions. When merging with
`gh pr merge`, use `--match-head-commit` with the reviewed head SHA so a later
push cannot silently replace the accepted candidate.

## Synchronizing hosted and local work

The worktree integrator updates local `dev`. GitHub updates the hosted branch
when a contribution merges. Keep these two writers in order:

1. Pause local integration while accepting a hosted contribution. Agents can
   keep editing their own branches. Publish accepted local changes with
   `git push origin dev` before merging the hosted pull request.
2. Review and merge the pull request against `dev`, retaining its contributor
   commits. A normal merge commit preserves their authorship and ancestry.
3. Adopt the hosted tips before resuming local integration. In the integration
   repository, ensure neither `main` nor `dev` is checked out in any worktree,
   then run:

   ```sh
   git fetch --atomic origin refs/heads/main:refs/heads/main refs/heads/dev:refs/heads/dev
   ```

This fetch requires fast-forward updates and changes both refs together or
neither. It refuses a checked-out target.

If a push or fetch refuses divergent history, preserve both tips and reconcile
them on a separate branch with the affected checks. Never force either shared
branch to make synchronization pass.

Resume integration after reconciliation. Each clean worktree synchronizes its
own branch with the refreshed shared tips before integrating. Never rebase a
branch while someone is editing it.

`zig build infrastructure-check` exercises this procedure in disposable
repositories, including divergent and checked-out branches.

## Promoting a reviewed candidate

Select a coherent increment from `dev` and publish a fixed snapshot for review
against `main`. Other work can continue on `dev`. Keep promotions small so each
can be reviewed as a whole.

From the integration repository, choose a fresh promotion branch name and
publish the exact candidate:

```sh
candidate=$(git rev-parse refs/heads/dev)
git push --force-with-lease=refs/heads/promote/topic: origin "$candidate:refs/heads/promote/topic"
gh pr create --base main --head promote/topic --web
```

The lease permits a new branch or a retry of the same candidate. It refuses to
replace an existing review with a different commit.

Review the complete diff against `main`, resolve review threads, and wait for
the required checks on the latest candidate. Any source or base change needs
the affected checks again. Merge promotions with a merge commit so the reviewed
`dev` commits remain ancestors of `main`. Squashing or rebasing a promotion
would discard that relationship and complicate later worktree integration.

After review and successful checks, merge that same candidate:

```sh
gh pr merge promote/topic --merge --match-head-commit "${candidate:?Set candidate to the reviewed commit SHA}"
```

Adopt the resulting hosted tips through the synchronization procedure above.

Only the maintainer merges into `main`. Pages and tagged releases each run
`tools/check/require-main-check.py`, which requires a successful `check.yml`
push run on `main` for the exact commit being published.
Passing `dev` or pull-request checks does not authorize publication.

## Repository protection

The versioned [main ruleset](../.github/rulesets/main.json) and
[dev ruleset](../.github/rulesets/dev.json) define the settings to activate and
verify on GitHub. Committing these files does not enable protection.
Once activated, `main` requires a pull request, resolved conversations, current
GitHub Actions checks, and a
merge commit. `dev` allows fast-forward pushes from local integration. Both
block force pushes and deletion without bypasses.

No second approving review is required. Authors cannot approve their own pull
requests, and automated review is not a second human. Require human approval
in the ruleset and its file once another responsible reviewer is available.

To activate protection, inspect existing rulesets, then
[import the missing rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/managing-rulesets-for-a-repository#importing-a-ruleset)
under **Settings**, **Rulesets**. Review each imported rule before creating it.
For later changes, update the existing ruleset and its versioned file together
rather than creating a duplicate.

Confirm on GitHub that an unchecked candidate cannot merge and a checked
candidate can. Keep fork workflows on GitHub-hosted runners with a read-only
token and no repository secrets. Review unfamiliar contributors' workflows
before approving their execution.
