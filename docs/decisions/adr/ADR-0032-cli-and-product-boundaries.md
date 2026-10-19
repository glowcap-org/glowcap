---
id: ADR-0032
status: accepted
date: 2026-10-19
tags: ["cli", "driver", "mcp", "packaging", "operability", "repository", "apps", "tools"]
decision: "The installable glowcap binary owns product argv, help and completion through one command registry."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0032 CLI and product boundaries

## Context

Product commands, contributor checks and deployment operations run in different environments. Combining them behind one script would make stopping a deployment depend on a source checkout and compiler.

## Decision

The installable glowcap binary owns product argv, help and completion through one command registry. CapTP verbs, REPL and curated MCP project that registry. Rooms participation uses the shared Rust application through its private command front rather than a second participant implementation.

Contributor checks are Zig build steps. Generators and check tools live under tools, while product binaries and applications live with their products. Deployment uses the product's operations surface and an immutable verified product snapshot. A running deployment does not mount mutable checkout output as its program.

Installation and deployment share the generated product inventory. Docker and Compose remain explicit external prerequisites, and their data targets come from the deployment configuration.

## Alternatives and consequences

A root script for every operation would mix machine configuration, toolchain and product concerns. Routing every deployment operation through a compiler would impose the wrong prerequisite on a running host. A second shell command tree would duplicate help and lifecycle ownership.

The command surface does not establish that release assets are published or that a deployment is reachable. [Maintaining](../../maintaining.md) and [packaging](../../../bindings/PACKAGING.md) own promotion and publication.

## Evidence

CLI command tests, generated completion, package smoke checks and Rooms agent proofs exercise the shipped fronts. `zig build source-check` holds placement and documented build steps.
