---
id: ADR-0076
status: accepted
date: 2026-11-07
tags: ["release", "bindings", "packaging", "public-surface"]
decision: "The publish workflow points the Racket catalog's entry at the release's binding archive through the catalog's API, with the catalog account held as secrets of an approval-gated environment."
supersedes: []
superseded_by: []
amends: [ADR-0075]
amended_by: []
---

# ADR-0076 Racket catalog publication

## Context

[ADR-0075](ADR-0075-release-publication-at-the-tag.md) publishes every language package from the tag's commit through `publish.yml`, and each registry's trusted-publisher binding authenticates the run with its OIDC token. The Racket package catalog at pkgs.racket-lang.org has no such binding and no API token: an entry is owned by an account with an email and a password, and names a package source the catalog reads for its checksum. The catalog's website edits an entry with one authenticated JSON call to its backend (`/api/package/modify-all`, HTTP Basic credentials), and re-reads the source as soon as the edit is saved.

A Git source for this repository fails in the catalog, because Racket's checkout refuses the repository's relative symlinks. The release therefore ships the binding as `glowcap-racket-<tag>.zip` with its SHA-1 checksum file, and every release's archive has a new URL, so a release that reaches Racket users needs an edit of the entry.

## Decision

`publish.yml` gains a `racket` job in a `racket` environment with the maintainer as required reviewer and the `v*` tag policy, like the other registry jobs. The environment holds the catalog account's email and password as secrets, which `tools/release-publishers.py` stores. `ci/racket_catalog.py` sets the entry's source to the release's archive through the catalog's own call, creating the package when the catalog lacks it, leaves an entry that already names the release alone, and waits until the public catalog states the archive and the release's checksum. The job then installs the package from the catalog into a fresh Racket, as the other jobs install their packages from their registries, and `validate-release.yml` repeats that install on its schedule. The entry's description and tags come from `bindings/racket/catalog.json`, so the catalog page is written once in the tree.

## Alternatives and consequences

A maintainer editing the entry after each release was the state ADR-0075 described. It left a routine release step to a person, so a release could reach every registry and still not reach Racket users. A fixed archive URL that each release overwrites would keep the entry unchanged, but GitHub serves a `latest` asset URL only for a release that is not a prerelease, and a changing archive behind an unchanged entry breaks `raco pkg install` from the release until the catalog's next hourly re-read, because the install checks the download against the checksum the catalog last stated. A branch holding the packaged collection as a Git source would commit generated state and move the release's authority out of the tag's archive.

The cost retained is a password in CI. The catalog offers no narrower credential, so the secret belongs to the environment whose reviewer approves each use, and it is the one credential in the publication path that is not a run-scoped token. A credential the catalog scopes to a package or a workflow would justify replacing it.

## Evidence

`ci/racket_catalog_test.py` drives the publisher against a fake catalog: the unchanged entry, creation and modification, the wait and its deadline, and each refusal. `ci/publish_test.py` holds the job's environment, permissions, secrets, and step order, and the pinned Racket in both installing workflows. `tools/release_publishers_test.py` holds the setup command's secret storage and dispatch against a fake `gh`. `tools/check/binding_packages.py --registry <version> racket` is the install from the live catalog, which runs only in `publish.yml` and `validate-release.yml`.
