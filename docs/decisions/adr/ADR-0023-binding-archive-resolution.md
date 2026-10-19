---
id: ADR-0023
status: accepted
date: 2026-10-19
tags: ["bindings", "c-abi", "packaging", "public-surface"]
decision: "A shipped machine-readable contract defines archive versions, targets, naming, cache layout and permitted resolution paths."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0023 Binding archive resolution

## Context

A published binding must load compatible archives without assuming a monorepo checkout or shell helper exists on the user's machine.

## Decision

A shipped machine-readable contract defines archive versions, targets, naming, cache layout and permitted resolution paths. Loaders apply the configured override, verified download cache, allowed in-tree output and operating-system lookup in the declared order.

Downloads and extraction are language-native. The operator fetch script is a contributor tool, not an installation dependency. Checksums and safe extraction precede trust in a cache marker. Archive identity is checked before ordinary calls. Extraction rejects traversal, symlinks and hardlinks and uses a sanitized archive-tool environment. Caller-supplied tar options cannot change the checked extraction.

## Alternatives and consequences

An implicit checkout search would make local development succeed while a package fails. A single shell downloader would add an undeclared runtime prerequisite. Independent undocumented loader formulas would drift across languages.

Published-release lookup remains controlled by the contract's publication switch. A valid resolver implementation does not establish that release assets exist or are accessible. A release needs a cold-cache consumer check against its actual URL.

## Evidence

Resolution cases, target aliases, damaged archives and cache markers have shared contract tests. [The packaging guide](../../../bindings/PACKAGING.md) owns the transition to published assets.
