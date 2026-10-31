---
id: ADR-0023
status: accepted
date: 2026-10-19
tags: ["bindings", "c-abi", "packaging", "public-surface"]
decision: "A shipped machine-readable contract defines archive versions, targets, naming, cache layout and permitted resolution paths."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0075]
---

# ADR-0023 Binding archive resolution

## Context

A published binding must load compatible archives without assuming a monorepo checkout or shell helper exists on the user's machine.

## Decision

A shipped machine-readable contract defines archive versions, targets, naming, cache layout and permitted resolution paths. Loaders apply the configured override, verified download cache, allowed in-tree output and operating-system lookup in the declared order.

Each binding owns its download and extraction path. The operator fetch script is a contributor tool, not an installation dependency. Checksums and safe extraction precede trust in a cache marker. Archive identity is checked before ordinary calls. Extraction rejects traversal, symlinks and hardlinks and uses a sanitized archive-tool environment. Caller-supplied tar options cannot change the checked extraction.

## Alternatives and consequences

An implicit checkout search would make local development succeed while a package fails. A single shell downloader would add an undeclared runtime prerequisite. Independent undocumented loader formulas would drift across languages.

A valid resolver implementation does not establish that release assets exist or are accessible. A release needs a cold-cache consumer check against its actual URL, which [ADR-0075](ADR-0075-release-publication-at-the-tag.md) places in the publication workflow.

## Evidence

Resolution cases, target aliases, damaged archives and cache markers have shared contract tests. [The packaging guide](../../../bindings/PACKAGING.md) owns the resolution order and the download controls.
