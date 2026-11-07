---
id: ADR-0075
status: accepted
date: 2026-10-31
tags: ["release", "bindings", "packaging", "public-surface"]
decision: "A signed version tag publishes the archives, the images, and every registry package from one commit, and a binding downloads its own version whenever it runs outside a checkout."
supersedes: []
superseded_by: []
amends: [ADR-0023]
amended_by: [ADR-0076]
---

# ADR-0075 Release publication at the tag

## Context

[ADR-0073](ADR-0073-hosted-landing-and-promotion.md) makes a release a maintainer-signed `v*` tag on `main`, and `release.yml` publishes the archives and container images from that commit. The language packages carry the same version and download the archives of that version, so a package built from any other commit names archives it was not tested with. ADR-0023 gated downloads behind a contract field that could only turn on after a release existed, which forced the packages of a version onto a commit after its tag.

## Decision

The tag's commit is the only source of a version. `release.yml` publishes the GitHub release, then dispatches [`publish.yml`](../../../.github/workflows/publish.yml) at the tag. That workflow verifies the signed tag, the checked `main` commit, and the public release, then uploads the crate, the wheel, and the JSR packages through each registry's trusted-publisher binding, skipping a version the registry already holds. Each upload is followed by an install of the published version in a fresh consumer with no local archives, so the package's own download path is the proof. A maintainer dispatches the same workflow to finish a publication an outage interrupted. The release contract refuses a version whose `CHANGELOG.md` section is missing before any build, and the release notes open with that section, so what changed is written once. Every archive, the checksum file, and the Rooms image carry a build provenance attestation from the release workflow, the provenance bundle of each asset is published beside it, and the image's software bill of materials is attested with it. The release is a draft until it holds every asset, and the repository's immutable-releases setting then holds it as published. `tools/release-tag.py` is the maintainer's front for the tag: it refuses a `main` that does not state the version, lacks the changelog section, or has not passed full validation, and otherwise signs and pushes the tag as its one effect.

A binding decides whether to download from where it runs. Outside a checkout it downloads its version unless `GLOWCAP_SKIP_DOWNLOAD` is set. Inside a checkout, found by `build.zig` beside `include/glowcap_ocapn.h`, it uses `zig-out` and downloads only with `GLOWCAP_DOWNLOAD`. The contract carries no publication switch. `source-check` holds every package manifest to the one `abi_version` in `build.zig`, so a bump that misses a manifest fails before it is tagged.

## Alternatives and consequences

A consumer-availability switch in the contract was rejected because it cannot be true at the commit that produces the release, so it splits one version across two commits. Publishing packages from `release.yml` itself was rejected because a registry step that fails would block the GitHub release, and a package should be installable only after the archives it downloads exist. Publishing by hand from a maintainer's machine was rejected because it loses the trusted-publisher provenance and the commit identity.

A version that fails partway is finished, never replaced: a failed release job is re-run and resumes its own draft, a failed registry step is re-run or dispatched again, and registries refuse a republished version, so a defect found after a tag takes the next patch version. A separate recovery path that publishes one run's artifacts from another run was rejected because it needs a second set of inputs, duplicates every fact the ordinary path states, and rescues a version the never-replace policy already gives up. The Racket catalog has no trusted-publisher binding, and [ADR-0076](ADR-0076-racket-catalog-publication.md) owns how its entry follows the release.

## Evidence

`ci/publish_test.py` holds the workflow's predicates, environments, and permissions. `tools/check/version_lockstep_test.py` holds every tracked manifest and lock file to `abi_version`. `ci/github_release_test.py` covers the asset assembly, the draft resume, and the public-release contract, `ci/release_notes_test.py` the rendered page and its refusals, `ci/release_build_test.py` the workflow's job predicates, and `tools/gen/set_version_test.py` the one-command version bump. `.github/workflows/validate-release.yml` installs the newest release through the site and every package from its registry on a schedule. `tools/release_tag_test.py` drives `tools/release-tag.py` against a local origin and a stub `gh`. `tools/release_publishers_test.py` drives `tools/release-publishers.py`, the registry setup command, against fake registries and a stub `gh`. `tools/c-abi/c-abi-resolve-cases.json` fixes the download decision for a checkout and a package in every resolver, and `zig build bindings-package-check` rehearses each package from the tree. The registry installs run only in `publish.yml`, so a registry's behavior is observed at each release and not in CI.
