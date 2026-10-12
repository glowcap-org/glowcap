---
id: ADR-0148
status: accepted
date: 2026-09-12
tags: [rooms, rust, architecture, platform, services]
decision: "Rooms host effects and product services are separate Rust crates: rooms-platform adapts the operating system and async executor, while rooms-services composes application and runtime owners into peers and fronts."
supersedes: []
superseded_by: []
amends: [ADR-0147]
amended_by: [ADR-0151, ADR-0174]
---

# ADR-0148 Rooms host platform and services

## Context

`rooms-native` mixed two boundaries. Tokio scheduling, filesystem custody,
listeners, TLS, WebSocket channels, room and session peers, IRC fronts, the web
front, and interactive commands all lived in one crate. The name described where
the code ran, not what it owned, and made platform effects look like part of
each service's policy.

The browser projects portable `rooms-application` and `rooms-runtime` owners
through browser-specific effects. Moving browser APIs or presentation state into
those crates would create false portability. The host side needs the same
distinction between shared policy, platform effects, and product composition.

## Decision

Replace `rooms-native` with two responsibility-bearing crates:

- `rooms-platform` owns Tokio clocks and task handles, operating-system
  entropy, leased filesystem directories and atomic replacement, transport
  listeners, system TLS trust, and WebSocket byte channels.
- `rooms-services` composes room, session, archive, IRC, web, and interactive
  service owners from `rooms-application`, `rooms-glowcap`, `rooms-runtime`,
  and `rooms-platform`.

The platform crate contains no Rooms service policy. The service crate does
not hide platform effects behind re-exported modules. `rooms-runtime` remains
the shared execution and reconciliation authority used by browser and host
consumers. Browser WebRTC, IndexedDB, JavaScript promises, and UI projections
remain in `rooms-browser` because their effects and recipients are specific to
that host.

The host adapter is named `HostPlatform`, not `Deadline`: it supplies clocks,
task spawning, fresh identifiers, and wall time in addition to deadlines.
Service binaries use the positive `processes` feature for process-only fronts.
No compatibility `rooms-native` crate remains.

Within `rooms-services`, modules name the responsibility directly: `server`
owns the Rooms server, `session` owns the durable session peer, and
`archive::peer` owns the standalone archive peer. Their former
`room_server`, `session_service`, and `archive::service` names repeated context
the crate already supplies or understated the module's responsibility.

## Consequences

The dependency direction is explicit:

```text
rooms-application <- rooms-glowcap <- rooms-runtime
        ^                  ^               ^
        |                  |               |
        +----------- rooms-platform -------+
                               ^
                               |
                        rooms-services

rooms-browser -> rooms-application + rooms-glowcap + rooms-runtime
```

The source gate rejects a return of `rooms-native`, a service dependency in a
shared or platform crate, and host platform dependencies in the browser crate.
The Rust workspace and build steps compile and lint both new crates together.

This split does not claim that every host specialization belongs in
`rooms-platform`. Thin type aliases that compose `rooms-runtime` with
`HostPlatform` stay beside the service that consumes them unless another host
consumer gives the abstraction an independent owner. Shared behavior still
belongs in `rooms-application` or `rooms-runtime`, with cross-host proof.
