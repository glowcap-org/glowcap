---
id: ADR-0062
status: accepted
date: 2026-06-15
tags: [net, driver, transport, c-abi, public-surface, vocabulary]
decision: "Each application layer has one locator-aware connection front door. OCapN owns the typed locator value and URI grammar. Transport packages own constructors and provider execution."
supersedes: [ADR-0043]
superseded_by: []
amends: []
amended_by: [ADR-0096]
---

# ADR-0062 One typed-locator connection front door

## Context

A locator names a transport, designator, and hints. Accepting a host and port in
the connection function adds a second transport choice, and accepting URI text
makes parsing part of every dial. Both duplicate facts the locator carries.

The runtime still needs an explicit transport set. A locator is an OCapN value,
not a socket factory or a provider lease, so it cannot own the runtime that
realizes its transport.

## Decision

Every application surface has one connection operation, and it accepts a typed
locator. URI text is parsed at configuration, command-line, and other text
boundaries. Serialization is likewise explicit.

- OCapN owns locator structure, parsing, validation, cloning, inspection, and
  URI serialization.
- A transport package owns the constructors for the locator forms it realizes.
  TCP therefore exposes `tcp.locator`, `tcp.keyed.locator`, and
  `tcp.noise.locator`. iroh and onion expose their own `locator` constructors.
- A Zig `Netlayer` realizes one transport symbol. A provider may own several
  netlayers, as `tcp.Provider` owns the plain, keyed, and Noise TCP profiles.
- Generic driver code dispatches the locator's transport against a caller-owned
  `[]const net.netlayer.Netlayer`. It names no concrete transport.
- Zig callers keep provider state explicit because they own `std.Io`, allocator
  choice, and provider lifetime. Binding product modules own their managed
  runtime integration. Importing a transport package is the corresponding
  composition step.
- The owning `driver.connect` and borrowing `driver.connectVia` remain separate
  because they expose different memory and lifetime contracts. Both take the
  same typed locator. `driver.connectUriOwned` and `driver.connectUri` are text
  boundary helpers, not parallel transport APIs.
- `driver.acceptVia` is the transport-neutral borrowing accept operation.
  TCP-only `connectTcp` and `acceptTcp` constructors are not part of the public
  driver surface.

At the C boundary, `GlowcapLocatorView` is the fixed-layout borrowed vocabulary.
The OCapN archive owns construction and URI operations, while provider archives
borrow the view without linking another runtime. ADR-0096 owns the Host
application surface that consumes it.

## Consequences

- Adding a transport changes its provider package and locator helpers, not the
  generic driver or connection signature.
- A connection call cannot silently reinterpret URI text or select a transport
  that differs from the locator.
- Bindings can present idiomatic module syntax without duplicating locator
  semantics. Their transport constructors return the typed value `connect` accepts.
- Explicit Zig provider state makes runtime ownership visible. Managed bindings
  can hide allocator and native-handle details without hiding which transport
  package the application imported.

## Alternatives considered

**Keep transport-specific connection functions.** Rejected: each new transport
would expand the generic application surface and create a second dispatch
authority.

**Let locators retain providers.** Rejected: a protocol value would carry
runtime authority, native resources, and language-specific lifetime state, and
parsing configuration text would compose providers.

**Make every binding expose Zig's netlayer slice.** Rejected: bindings own their
runtime adapter and native handle lifetimes, so the transport package boundary
is the common contract, and a Zig-shaped lifetime API in each language would
expose mechanism without adding control.

## Evidence

The Zig driver and interop scenarios run the same typed-locator connection and
accept contracts with TCP, iroh, onion, in-process, relay, and WebRTC backends.
WebRTC is signaling-owned and intentionally exposes no `Netlayer`. Its backend
still composes through the generic completion loop. Binding checks construct
typed locators through transport packages and pass them to one `connect`.
`zig build source-check` rejects transport-specific driver constructors and
generic binding ownership of locator construction.
