---
type: static
description: Reviewing and integrating changes locally as signed commits, then fast-forwarding main to a checked one.
sources:
  - resource: /.github/workflows/check.yml
  - resource: /.github/workflows/pages.yml
  - resource: /.github/workflows/release.yml
  - resource: /tools/check/publication-integration-test.sh
  - resource: /tools/check/require-main-check.py
  - resource: /.github/rulesets/
  - resource: /tools/deps/fetch-mbedtls.sh
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
worktree. It makes one commit from the branch's tree and signs it with the
maintainer's SSH key, verified against the allowed-signers file, so every
commit on `dev` carries the maintainer's signature even when an agent wrote
the draft commits. Without a reachable key it refuses and moves nothing. An
evidence note on the branch commit moves onto the signed one.

With authorization to publish accepted changes, run:

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
separate. Close out-of-scope work with a reason.

An accepted contribution lands through the worktree integrator, never through
the merge button, so `dev` keeps one signed commit per change. Fetch the
reviewed head into a branch of its own and add a worktree on it:

```sh
git fetch origin "refs/pull/${number:?}/head:refs/heads/review/${number}"
git worktree add ".local/worktrees/review-${number}" "review/${number}"
```

Run the integrator from that worktree, then push `dev` as above.

The landed commit keeps the contributor as author when every commit on the
branch is theirs, and the maintainer's signature says who vouched for it.
Close the pull request naming the landed commit, because GitHub cannot match
a re-signed commit to the branch it came from.

## Synchronizing hosted and local work

The worktree integrator is the only writer of `dev`, and `main` moves only by
fast-forward from a commit on `dev`. The hosted and local copies of both
branches can still drift when a push is interrupted or a second machine
integrates. Adopt the hosted tips before resuming local integration: in the
integration repository, ensure neither `main` nor `dev` is checked out in any
worktree, then run:

```sh
git fetch --atomic origin refs/heads/main:refs/heads/main refs/heads/dev:refs/heads/dev
```

This fetch requires fast-forward updates and changes both refs together or
neither. It refuses a checked-out target, so when the primary checkout holds
`main`, fetch `dev` alone that way and fast-forward `main` in its checkout
with `git merge --ff-only origin/main` after a plain fetch. If a push or
fetch refuses divergent
history, preserve both tips and reconcile them on a separate branch with the
affected checks. Never force either shared branch to make synchronization
pass. Each clean worktree then synchronizes its own branch with the refreshed
shared tips before integrating, and nobody rebases a branch someone is editing.

`zig build infrastructure-check` exercises this procedure in disposable
repositories, including divergent and checked-out branches.

## Promoting to main

`main` is a fast-forward of `dev`, so the commit the checks ran on is the
commit that publishes: the same hash, signature, and evidence note. Choose a
coherent increment, confirm it is on `dev` with a green push run, then move
`main` to it:

```sh
candidate=$(git rev-parse refs/heads/dev)
git merge-base --is-ancestor "$candidate" refs/heads/dev
gh run list --commit "$candidate" --workflow check.yml
git push origin "$candidate:refs/heads/main"
git merge --ff-only "$candidate"
```

The push goes first so the remote's rules judge the candidate, and the merge
then moves local `main` in the checkout that holds it. A refused push leaves
both where they were.

The main ruleset accepts only a fast-forward of signed commits whose required
checks passed, so the remote rejects a merge, a squash, a rewrite, or a
candidate without a green `gates` and `macos-runtime` run. Nothing is
squashed or merged on the way, because either would replace the checked
commit with one no check ran on.

The site is published at `glowcap.org`. The custom domain is set in the
repository's Pages settings, because a Pages deployment from Actions ignores a
`CNAME` file in its artifact. The DNS records live with the domain's DNS host
and the domain verification in the maintainer's GitHub account settings.

Only the maintainer moves `main`. Pages and tagged releases each run
`tools/check/require-main-check.py`, which requires a successful `check.yml`
push run on `main` for the exact commit being published.
Passing `dev` checks alone does not authorize publication.

Every run of `ci/gates.sh` writes an evidence record to
`zig-out/evidence/<commit>.json`: the commit, the hash of the working tree
the gates ran on, whether that tree is the commit's, the submodule revisions, the toolchain pins' digests, the host,
and every gate with its exit status and duration. The checks workflow keeps
the record as the `evidence-<commit>` artifact on success and failure alike,
and a run on a clean checkout also attaches it to the commit as a git note
under `refs/notes/evidence`. A green run whose record step fails exits 70,
because a check without its record is not evidence. A branch push leaves
notes behind, so publish them with `git push origin refs/notes/evidence`.

## Repository protection

The versioned [main ruleset](../.github/rulesets/main.json) and
[dev ruleset](../.github/rulesets/dev.json) define the settings to activate and
verify on GitHub. Committing these files does not enable protection. Once
activated, both branches take only signed commits in a linear history, and
neither can be force-pushed or deleted. `main` also requires the `gates` and
`macos-runtime` checks to have passed on the pushed commit. There is no
bypass, so the maintainer's own push answers to the same rules.

GitHub verifies a signature only against a signing key on the maintainer's
account, so upload the public key as a signing key before activating the
rulesets.

To activate protection, inspect existing rulesets, then
[import the missing rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/managing-rulesets-for-a-repository#importing-a-ruleset)
under **Settings**, **Rulesets**. Review each imported rule before creating it.
For later changes, update the existing ruleset and its versioned file together
rather than creating a duplicate.

Confirm on GitHub that an unsigned or unchecked push to `main` is refused and
a checked fast-forward is accepted. Keep fork workflows on GitHub-hosted
runners with a read-only token and no repository secrets. Review unfamiliar
contributors' workflows before approving their execution.

## Relay TLS maintenance

The optional `wss` carrier compiles a private, minimal Mbed TLS release.
[`tools/deps/fetch-mbedtls.sh`](../tools/deps/fetch-mbedtls.sh) is the single
version, release URL, archive-size ceiling, and SHA-256 authority. Updating it
is a security-sensitive dependency change:

1. Select an upstream-supported official release and read its security and
   migration notes, including the bundled TF-PSA-Crypto version.
2. Update the version and archive digest together, then review the extracted
   directory allowlist, the compiled source inventory in
   `tools/build/mbedtls.zig`, and both minimal configuration headers under
   `src/net/tls/` for newly required or newly reachable code.
3. Run `zig build relay-tls-build` and `zig build check`, then run the static
   and shared packaging checks on every supported platform. The
   TLS check must retain exact success, hostname, CA, expiry, alert, malformed
   record, truncation, close-notify, and symbol-isolation evidence.
4. Update `LICENSE-THIRD-PARTY`, build-step documentation, and the public pin
   description in the same change. Never silently float the release or accept
   an unverified archive.

The committed localhost certificate chain is test-only. The TLS check
verifies its authority and fails when the leaf nears expiry.
Renew the entire root and leaf together into a new directory with
`tools/check/generate-relay-tls-fixture.sh`, inspect the subjects, SAN,
validity, and private-key diff, then replace the three files under
`test/net/fixtures/` in one reviewed commit. Generate a fresh root key each
time, and use these keys only in tests. Never weaken the expiry check to buy
time.
