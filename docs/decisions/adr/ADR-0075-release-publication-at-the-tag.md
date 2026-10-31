---
id: ADR-0075
status: accepted
date: 2026-10-31
tags: ["release", "bindings", "packaging", "public-surface"]
decision: "A signed version tag publishes the archives, the images, and every registry package from one commit, and a binding downloads its own version whenever it runs outside a checkout."
supersedes: []
superseded_by: []
amends: [ADR-0023]
amended_by: []
---

# ADR-0075 Release publication at the tag

## Context

[ADR-0073](ADR-0073-hosted-landing-and-promotion.md) makes a release a maintainer-signed `v*` tag on `main`, and `release.yml` publishes the archives and container images from that commit. The language packages carry the same version and download the archives of that version, so a package built from any other commit names archives it was not tested with. ADR-0023 gated downloads behind a contract field that could only turn on after a release existed, which forced the packages of a version onto a commit after its tag.

## Decision

The tag's commit is the only source of a version. `release.yml` publishes the GitHub release, then dispatches [`publish.yml`](../../../.github/workflows/publish.yml) at the tag. That workflow verifies the signed tag, the checked `main` commit, and the public release, then uploads the crate, the wheel, and the JSR packages through each registry's trusted-publisher binding, skipping a version the registry already holds. Each upload is followed by an install of the published version in a fresh consumer with no local archives, so the package's own download path is the proof. A maintainer dispatches the same workflow to finish a publication an outage interrupted. The release contract refuses a version whose `CHANGELOG.md` section is missing before any build, and the release notes open with that section, so what changed is written once. The Rooms image carries the same publication attestation as the archives.

A binding decides whether to download from where it runs. Outside a checkout it downloads its version unless `GLOWCAP_SKIP_DOWNLOAD` is set. Inside a checkout, found by `build.zig` beside `include/glowcap_ocapn.h`, it uses `zig-out` and downloads only with `GLOWCAP_DOWNLOAD`. The contract carries no publication switch. `source-check` holds every package manifest to the one `abi_version` in `build.zig`, so a bump that misses a manifest fails before it is tagged.

## Alternatives and consequences

A consumer-availability switch in the contract was rejected because it cannot be true at the commit that produces the release, so it splits one version across two commits. Publishing packages from `release.yml` itself was rejected because a registry step that fails would block the GitHub release, and a package should be installable only after the archives it downloads exist. Publishing by hand from a maintainer's machine was rejected because it loses the trusted-publisher provenance and the commit identity.

A version that fails partway is finished by a second dispatch, never replaced: registries refuse a republished version, so a defect found after a tag takes the next patch version. The Racket catalog has no publishing API, so its entry is maintained by hand and points at the tag.

## Evidence

`ci/test/publish_test.py` holds the workflow's predicates, environments, permissions, and pins. `ci/test/release_recovery_test.py` covers the public-release contract, `ci/test/release_notes_test.py` the changelog and attestation predicates, and `ci/test/set_version_test.py` the one-command version bump. `tools/c-abi/c-abi-resolve-cases.json` fixes the download decision for a checkout and a package in every resolver, and `zig build bindings-package-check` rehearses each package from the tree. The registry installs run only in `publish.yml`, so a registry's behavior is observed at each release and not in CI.
