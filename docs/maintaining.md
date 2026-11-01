---
type: static
description: Landing changes on dev as signed commits, the workflow that fast-forwards main to each checked one, and release protection.
sources:
  - resource: /.github/workflows/check.yml
  - resource: /.github/workflows/pages.yml
  - resource: /.github/workflows/promote.yml
  - resource: /.github/workflows/release.yml
  - resource: /.github/workflows/publish.yml
  - resource: /.github/workflows/validate-release.yml
  - resource: /.github/workflows/scorecard.yml
  - resource: /.github/workflows/repository-policy.yml
  - resource: /.github/zizmor.yml
  - resource: /.github/repository-policy.json
  - resource: /tools/check/github_release.py
  - resource: /tools/release-tag.sh
  - resource: /tools/release-publishers.py
  - resource: /tools/repository-policy.py
  - resource: /tools/check/publication-integration-test.sh
  - resource: /tools/check/release-tag-test.sh
  - resource: /tools/gen/set_version.py
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

glowcap is an Apache-2.0 alpha. A public repository or a tagged archive
does not promise API, ABI, or storage compatibility. Release publication
accepts only `0.x.y` versions and marks each GitHub release as a prerelease,
without assigning it the latest stable release label. A stable release
requires a deliberate change to this policy and its workflow checks.

Registry identities live in
[binding packaging](../bindings/PACKAGING.md#package-ownership), and
[releasing a version](#releasing-a-version) is the procedure.

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
deploy. Rerun a refused release with `gh run rerun <run-id>` when its workflow
needs no correction. Reruns use the tagged workflow, including its defects.
A manual `check` defaults to full validation. Select `suite=fuzz` for the
separate long fuzz search.

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

## Releasing a version

A release is a maintainer-signed `v<version>` tag on `main`. Its commit is the
one source of that version's archives, container images, and language
packages ([ADR-0075](decisions/adr/ADR-0075-release-publication-at-the-tag.md)).
A published version is never replaced: a defect found after the tag takes the
next patch version, and the repository's immutable-releases setting holds every
published release and its assets as they were.

Each change lands with its entry under `Unreleased` in `CHANGELOG.md`. The
release itself is two commands and two workflows.

1. Run `zig build set-version -Dversion=<version>`. One command moves every
   stated version in one diff: `abi_version` in `build.zig`, the C ABI
   constants and header, `build.zig.zon`, the archive-resolution contract and
   its package copies, every tracked package manifest and lock file, the pages
   that state the release version, and the binding constants that embed it.
   It dates the `Unreleased` entries as the version's changelog section.
   `source-check` and the locked builds refuse a tree where one disagrees.
   Land the bump on `dev` and let promotion move `main`.
2. Run `tools/release-tag.sh <version>` on the host that
   holds the signing key. It requires that `main` states the version, carries
   its changelog section, has no such tag on origin, and passed full
   validation. Then it signs `v<version>` at that commit and pushes the tag,
   its one effect. Every refusal names what to land first.
3. The [release workflow](../.github/workflows/release.yml) requires the
   commit's successful validation on `main` and the version's changelog
   section before it builds. Each host attests the build provenance of the
   archives it builds, and each Linux host proves the Rooms image from its
   exact product archive. One job then publishes the image by digest with its
   provenance and software bill of materials, renders the release page from
   the verified archives, and fills a draft release with every asset and its
   provenance bundle. The draft becomes public only when it holds every asset,
   and the public release dispatches the
   [publish workflow](../.github/workflows/publish.yml) at the tag.
4. The publish workflow checks out the tag and verifies the public release.
   It uploads the crate, the wheel, and the JSR packages as each registry's
   trusted publisher. Then it installs every published package in a fresh
   consumer that downloads the release's C SDK. Each registry job waits for
   the maintainer's approval in its environment. Then run
   `tools/release-publishers.py`, which names the Racket catalog entry when
   it lags the release and walks through the change.

A failed job is re-run from the run's page with **Re-run failed jobs**. The
release job resumes its own draft, skips an image tag it already pushed, and
refuses a published release or another run's draft. A registry outage is
finished the same way, or by dispatching the publish workflow again at the
tag, because every registry step skips a version its registry already holds:

```sh
gh workflow run publish.yml --ref v0.1.1 -f tag=v0.1.1
```

A manual run of the release workflow rehearses the builds and the image proofs
without attesting or publishing. The
[validation workflow](../.github/workflows/validate-release.yml) runs weekly
and on demand: it installs the newest release through the site's installer on
each host and installs every published package from its registry, so a reader
never finds the drift first.

Every archive, the checksum file, and the image carry a build provenance
attestation signed by the release workflow. The release page shows the
verification commands. The one for an archive is:

```sh
gh attestation verify --repo glowcap-org/glowcap <archive>
```

### Registry publishers

Each registry trusts `publish.yml` in this repository through an OpenID
Connect binding that names the workflow file and a GitHub environment. The
environments `pypi`, `crates-io`, and `jsr` hold the maintainer as a required
reviewer, so each publication waits for approval, and a deployment branch
policy admits `v*` tags, so the dispatch at the tag can enter them.

`tools/release-publishers.py` is the one command for this setup. It verifies
each registry against what the registry and GitHub answer, and creates or
repairs the environments itself. For a step only a person can take in a
browser it prints the page and the exact values, opens the page, and verifies
again once the step is confirmed. `--check` verifies without prompts or
effects, so a script can run it. The names it enters come from the tree: the
JSR scope and packages from the TypeScript workspace, the crate and the PyPI
project from their manifests, and the repository from `gh`.

| Registry | What a person does once |
| --- | --- |
| PyPI | Registers a pending trusted publisher for the project. It becomes the project's publisher at the first upload, and the command reports it as waiting until then. |
| crates.io | Stores a publish token as the `CARGO_REGISTRY_TOKEN` secret of the `crates-io` environment for the first upload, because a trusted publisher binds to an existing crate. After that upload, adds the trusted publisher, and the command deletes the secret. |
| JSR | Creates each workspace package in the `@glowcap` scope and links it to this repository. |
| Racket catalog | Creates the `glowcap` entry with the source the command prints, and moves its tag after each release. |

## Promotion app

The promote workflow acts as an organization-owned GitHub App, because a
workflow's own token may not move a branch across commits that change workflow
files. The app holds four repository permissions on this repository alone:
Contents and Workflows, both read and write, which promotion needs, and
Administration and Code scanning alerts, both read-only, which the
[repository policy workflow](../.github/workflows/repository-policy.yml) needs
to read settings a workflow's own token cannot see. Its client ID is the
`PROMOTE_APP_CLIENT_ID` variable and its private key the
`PROMOTE_APP_PRIVATE_KEY` secret. Until both exist, promotion fails at its
first step and `main` stays where it was.

1. Under the organization's **Settings**, **Developer settings**, **GitHub
   Apps**, choose **New GitHub App**. Name it `glowcap-promote`, set the
   homepage to `https://glowcap.org`, clear **Active** under webhooks, set the
   Contents and Workflows repository permissions to **Read and write**, the
   Administration and Code scanning alerts permissions to **Read-only**, and
   allow installation only on this account.
2. Copy the client ID, generate a private key, and install the app on
   `glowcap-org/glowcap` only.
3. In the glowcap repository's **Settings**, open **Secrets and variables**,
   then **Actions**. Select **Variables** and choose **New repository variable**
   under **Repository variables**. Name it `PROMOTE_APP_CLIENT_ID` and use the
   app's client ID as its value.
4. Select **Secrets** and choose **New repository secret** under **Repository
   secrets**. Name it `PROMOTE_APP_PRIVATE_KEY` and paste the entire downloaded
   `.pem` file as its value. Delete the downloaded key after saving it.

The CLI equivalent is:

```sh
gh variable set PROMOTE_APP_CLIENT_ID -R glowcap-org/glowcap --body "${client_id:?}"
gh secret set PROMOTE_APP_PRIVATE_KEY -R glowcap-org/glowcap < "${key_file:?}"
```

Rerun a refused promotion with `gh run rerun <run-id>`. To rotate the key,
generate a new one, store it the same way, then delete its predecessor in the
app's settings. An installed app gains a permission under its own settings, and
the organization then accepts the change under **Installed GitHub Apps**.

## Repository protection

The repository's settings and rulesets are data in this tree, and one command
holds GitHub to them.
[`repository-policy.json`](../.github/repository-policy.json) states the
settings: the merge method, secret scanning with push protection, Dependabot
alerts and updates, private vulnerability reporting, immutable releases, code
scanning, and the Actions policy. The Actions policy requires every action to
be pinned to a commit, gives workflows a read-only token, and forbids them
from approving pull requests. A workflow run from an outside contributor's
fork waits for the maintainer's approval, who reads its workflow changes
first. The [main ruleset](../.github/rulesets/main.json),
[dev ruleset](../.github/rulesets/dev.json),
[release tag ruleset](../.github/rulesets/tags.json), and
[tag immutability ruleset](../.github/rulesets/tag-immutability.json) sit
beside it.

`tools/repository-policy.py` reports every difference between GitHub and
these files, and `--apply` makes GitHub match, creating a missing ruleset and
updating a changed one. A ruleset on GitHub that no file describes is reported
and left for a person to review. Change a setting in its file, run the command
with `--apply`, and land the file in the same change.

Both branches take only signed commits in a linear history, and neither can be
force-pushed or deleted. `main` also requires the `gates` and `macos-runtime`
checks to have passed on the pushed commit. Only the repository's
administrator can create a `v*` tag. A pushed tag names a signed commit and
can neither move nor be deleted, and that ruleset has no bypass, so the
maintainer's own push answers to it. GitHub verifies a signature only against
a signing key on the maintainer's account, so upload the public key before
applying the rulesets.

A pull request's branch usually carries unsigned commits, because agents do
not sign, so the repository's administrator may merge one into `dev` past the
signature rule, and GitHub signs the squash commit it creates. No push bypasses
the rule, and nothing bypasses `main`.

Immutable releases hold a published release and its assets as they were, which
is the policy the release workflow already follows.

Four workflows watch the posture without being asked. The `workflows` job of
the check workflow audits every workflow and action file with
[zizmor](https://docs.zizmor.sh) on each push and pull request, and
`.github/zizmor.yml` records a finding a design answers with its reason. The
`dependencies` job reviews every pull request's dependency changes against the
advisory database and fails on a known vulnerability at any severity. The
[scorecard workflow](../.github/workflows/scorecard.yml) publishes the
[OpenSSF Scorecard](https://scorecard.dev/viewer/?uri=github.com/glowcap-org/glowcap)
weekly and sends each finding to code scanning, where GitHub's own code
scanning, secret scanning, and Dependabot alerts also arrive. The
[repository policy workflow](../.github/workflows/repository-policy.yml) runs
`tools/repository-policy.py` weekly and on every change to the policy files,
with a read-only token of the [promotion app](#promotion-app), and fails on
any drift, which the maintainer's `--apply` resolves.

Run the zizmor audit locally with `uvx zizmor .`.

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
