---
id: ADR-0074
status: accepted
date: 2026-10-30
tags: ["transport", "build", "zig", "rust"]
decision: "A Zig package consumer links its selected Rust transports through one Cargo-built static library."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0074 Linking Rust transports from Zig

## Context

The iroh and WebRTC backends each embed Rust dependencies in a static library.
Linking both into a Zig executable produces duplicate Rust symbols. Importing
only their types hid this failure in the checkout-based consumer check.

## Decision

Zig dependency options `.iroh` and `.webrtc` select the published transport
modules. Their libraries come from the transport workspace's root crate, whose
Cargo features select the existing backend implementations. When both are
selected, Cargo resolves their dependencies together and emits one static
library. The workspace shares one lockfile.

Individual repository products keep their backend archives. The protocol core
stays independent of Rust, and endpoint runtimes remain endpoint-owned.

## Alternatives and consequences

Separate dynamic libraries would add installation and loader requirements.
Rewriting static symbols would require platform-specific handling of Rust
runtime symbols and relocations. One Cargo graph owns that work directly.
Consumers must select transport options before requesting those modules.

## Evidence

`consumer-check` fetches a filtered source archive and builds and runs core,
iroh-only, WebRTC-only, and combined consumers. Backend initialization function
references force real linking. The combined build exposed the original
duplicate symbols. This check runs on Linux and does not prove cross-compilation
or macOS package consumption.
