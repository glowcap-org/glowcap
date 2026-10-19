---
id: ADR-0059
status: accepted
date: 2026-10-19
tags: ["rooms", "persistence", "storage", "postgresql", "loam", "deployment"]
decision: "Directory authority uses versioned single-document files in the server state directory."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0059 Rooms retention storage

## Context

Directory authority, a member's managed workspace and derived public-room scrollback have different durability and capability requirements. Adding a service for a temporary derived-data seam would increase deployment cost without strengthening authority.

## Decision

Directory authority uses versioned single-document files in the server state directory. A member session's workspace uses its managed Loam store. Public-room kept lines use JSONL files under the state directory, or memory when no state directory is configured.

PostgreSQL is not a Rooms prerequisite. The planned room-content model can take ownership of kept lines and their quota when that integration exists. Existing JSONL retention does not claim that future storage model is shipped.

An application does not use derived scrollback as a source of member archive authority or managed grants. A deployment backs up state through its documented stopped-owner procedure.

## Alternatives and consequences

A separate PostgreSQL destination would require credentials, an image and backup operations for a seam being retired. A new Loam projection for capability-free derived rows would be temporary work beside the intended content model.

An unavailable configured authority store must refuse startup. Droppable retention and durable authority are not interchangeable recovery postures. Engine choice for the managed workspace follows the [default storage decision](ADR-0062-sqlite-default-storage.md).

## Evidence

Rooms retention, session reopen and deployment tests cover their actual stores. [The roadmap](../../roadmap.md) owns room-content integration, and [the session guide](../../rooms/session.md) owns managed startup.
