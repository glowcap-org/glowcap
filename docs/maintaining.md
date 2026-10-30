---
type: static
description: Landing changes on dev as signed commits, the workflow that fast-forwards main to each checked one, and release protection.
sources:
  - resource: /.github/workflows/check.yml
  - resource: /.github/workflows/pages.yml
  - resource: /.github/workflows/promote.yml
  - resource: /.github/workflows/release.yml
  - resource: /tools/check/publication-integration-test.sh
  - resource: /tools/check/require-main-check.py
  - resource: /.github/rulesets/
  - resource: /tools/deps/fetch-mbedtls.sh
---

# Maintaining glowcap

Every change lands on `dev`, the default branch: a pull request by squash
merge, a worktree branch through the integrator. `main`, the publication
branch, is the newest `dev` commit whose full check passed, and a workflow
moves it. A release is a maintainer-signed tag on `main`.
[ADR-0073](decisions/adr/ADR-0073-hosted-landing-and-promotion.md) records
the choice.

## Release status

glowcap 0.1.0 is an Apache-2.0 alpha. A public repository or a tagged archive
does not promise API, ABI, or storage compatibility. Release publication
accepts only `0.x.y` versions and marks each GitHub release as a prerelease,
without assigning it the latest stable release label. A stable release
requires a deliberate change to this policy and its workflow checks.

Registry identities and the corporate registration steps live in
[binding packaging](../bindings/PACKAGING.md#package-ownership).

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
below. Never force `dev`. The push starts full validation, and its success
promotes the commit to `main` and the site. Only a tag creates a release.

## Reviewing a contribution

Establish the problem and the behavior the patch changes. Read its tests and
run the focused check for the affected area. Check protocol claims against
their outside authority. Inspect executable changes to CI, dependencies,
permissions, and release tooling before approving a fork workflow to run.

Request changes for correctness, security, necessary coverage, or a documented
constraint. Explain why and mark optional suggestions. Keep unrelated cleanup
separate. Close out-of-scope work with a reason.

Accept a pull request with **Squash and merge**, pinned to the head you
reviewed so a later push cannot land unreviewed:

```sh
gh pr merge "${number:?}" --squash --match-head-commit "${reviewed:?}"
```

GitHub signs the squash commit and keeps the contributor as its author, so
`dev` takes one signed commit per change and the pull request closes as
merged. Fix a contribution's last details on its branch before merging, not in
a follow-up commit.

## Synchronizing hosted and local work

`main` moves only by fast-forward from a commit on `dev`, and it moves on
GitHub, so local `main` falls behind until the next fetch. The hosted and local
copies of both branches also drift when a push is interrupted or a second
machine integrates. Adopt the hosted tips before resuming local integration:
in the integration repository, ensure neither `main` nor `dev` is checked out
in any worktree, then run:

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
commit that publishes: the same hash, signature, and evidence note. Every push
to `dev` runs full validation, and a push to `dev` cancels any `dev` run still
in progress, so only the newest `dev` commit becomes a candidate.

When a push run on `dev` succeeds, the
[promote workflow](../.github/workflows/promote.yml) fast-forwards `main` to
its commit as the [promotion app](#promotion-app), and that push deploys the
site. A rerun of an older run finds `main`
past its commit and moves nothing. The main ruleset judges that move like any
push: it accepts only a fast-forward of signed commits whose `gates` and
`macos-runtime` checks passed, with no bypass. A merge, a squash, or a rewrite
would replace the checked commit with one no check ran on, so none is
accepted.

GitHub does not count a manually started run toward the ruleset, and only a
push run starts promotion. Retry a failed job in the push run with
`gh run rerun <run-id> --failed`, and its success promotes the commit.

Pages deploys `main`, and a tagged release publishes its tagged commit. Both
first run `tools/check/require-main-check.py`. It requires the commit to be on
`main` and to have a successful `check.yml` run, either the push run on `dev`
or a manual full check. Both `gates` and `macos-runtime` must complete
successfully in the same run attempt. The long fuzz search alone does not
authorize publication.

If a commit on `main` has no such run, start full validation explicitly:

```sh
gh workflow run check.yml --ref main -f suite=check
```

Once both required jobs pass, run `gh workflow run pages.yml --ref main` to
deploy. A release tag cannot move, so rerun its refused release run with
`gh run rerun <run-id>`. A manual `check` defaults to full validation. Select
`suite=fuzz` for the separate long fuzz search.

The site is published at `glowcap.org`. The custom domain is set in the
repository's Pages settings, because a Pages deployment from Actions ignores a
`CNAME` file in its artifact. The DNS records live with the domain's DNS host
and the domain verification in the maintainer's GitHub account settings.

Each `ci/gates.sh` run records the commit, working-tree hash and dirty state,
submodule revisions, toolchain pins, host, and each gate's exit status and
duration. A full local run writes `zig-out/evidence/<commit>.json` and, on a
clean checkout, attaches a Git note under `refs/notes/evidence`. A phase run
writes `zig-out/evidence/<phase>/<commit>.json` without attaching a note.

CI uploads these records as `evidence-<commit>-<phase>` artifacts on success
and failure. A green sequence whose record step fails exits 70. To publish
notes from a full local run, use `git push origin refs/notes/evidence`.

## Promotion app

The promote workflow acts as an organization-owned GitHub App, because a
workflow's own token may not move a branch across commits that change workflow
files. The app holds two repository permissions, Contents and Workflows, both
read and write, on this repository alone. Its client ID is the
`PROMOTE_APP_CLIENT_ID` variable and its private key the
`PROMOTE_APP_PRIVATE_KEY` secret. Until both exist, promotion fails at its
first step and `main` stays where it was.

1. Under the organization's **Settings**, **Developer settings**, **GitHub
   Apps**, choose **New GitHub App**. Name it `glowcap-promote`, set the
   homepage to `https://glowcap.org`, clear **Active** under webhooks, set the
   Contents and Workflows repository permissions to **Read and write**, and
   allow installation only on this account.
2. Copy the client ID, generate a private key, and install the app on
   `glowcap-org/glowcap` only.
3. Store both, then delete the downloaded key:

```sh
gh variable set PROMOTE_APP_CLIENT_ID -R glowcap-org/glowcap --body "${client_id:?}"
gh secret set PROMOTE_APP_PRIVATE_KEY -R glowcap-org/glowcap < "${key_file:?}"
```

Rerun a refused promotion with `gh run rerun <run-id>`. To rotate the key,
generate a new one, store it the same way, then delete its predecessor in the
app's settings.

## Repository protection

The versioned [main ruleset](../.github/rulesets/main.json),
[dev ruleset](../.github/rulesets/dev.json), and
[release tag ruleset](../.github/rulesets/tags.json) define the settings to
activate and verify on GitHub. Committing these files does not enable
protection. Once activated, both branches take only signed commits in a linear
history, and neither can be force-pushed or deleted. `main` also requires the
`gates` and `macos-runtime` checks to have passed on the pushed commit. A `v*`
tag must be signed, and once pushed it can neither move nor be deleted, so the
commit a release names stays the commit that was checked. There is no bypass,
so the maintainer's own push answers to the same rules.

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
