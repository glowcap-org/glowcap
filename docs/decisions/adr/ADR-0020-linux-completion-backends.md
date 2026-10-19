---
id: ADR-0020
status: accepted
date: 2026-10-19
tags: ["net", "linux", "runtime", "resilience", "performance"]
decision: "Linux prefers io_uring and falls back to epoll when the required facilities are unavailable."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0020 Linux completion backends

## Context

A library cannot assume its user controls kernel version, io_uring policy or the process log. Requiring one kernel facility would exclude hosts that can still implement the completion contract correctly.

## Decision

Linux prefers io_uring and falls back to epoll when the required facilities are unavailable. Both implement the same completion and shared-buffer ownership contract. The selected backend and fallback reason are typed runtime status.

The embedding decides whether and how to report that status. Initialization emits no library warning on its behalf.

## Alternatives and consequences

Requiring a host configuration change would turn an optional performance facility into a correctness prerequisite. Using epoll everywhere would discard the measured io_uring path. Logging during initialization would take ownership of an application's output.

Fallback preserves behavior, not an identical performance claim. The recorded high-session-count result used io_uring. No equivalent epoll scale result is implied. Windows and IOCP remain separate work.

## Evidence

Backend selection, refusal and shared behavior tests run under `zig build test`. The [platform evidence](../../stability.md) records what has actually run.
