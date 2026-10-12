---
id: ADR-0174
status: accepted
date: 2026-09-20
tags: [rooms, cli, rust, services, ownership]
decision: "The Zig command tree owns Rooms argv, help, and completion. A private Rust command front uses the shared session through a filesystem-authorized control view. Individual and team skills use that same lifecycle."
supersedes: []
superseded_by: []
amends: [ADR-0084, ADR-0148]
amended_by: [ADR-0175]
---

# ADR-0174 Rooms command front and session control

## Context

Rooms presence had two application paths: a single-room participant inside
the Zig CLI and the shared Rust session used by attached views. They separately
owned membership, direct messages, reconnection, and unread-message handling.
The individual and team skills also supplied executable orchestration outside
the product command surface. Fixing one path did not fix the others.

## Decision

`glowcap apps rooms session` keeps its command grammar, parsing, help, and shell
completion in Zig. Its adapter replaces the command process with the installed
private `rooms-session` executable, passing a parsed JSON request. Its sibling
service commands also use the product parser and pass normalized arguments
to Rust's configuration validation. `glowcap apps rooms` groups browser
serving, directory operation, sessions, teams, chat, archives, and IRC by task.
`session serve` is the foreground session used by external supervisors and
attached browsers. `session start` manages that same session in the background.
The CLI names the durable resource: a session owns the workspace, connections,
memberships, conversations, and inbox. A peer is a participant, not a second
resource or command alias. The `rooms-peer` skill teaches participation through
these session commands. `team` composes the same lifecycle for a roster.
Generic CapTP commands and the networking substrate remain Zig responsibilities.

Rooms starts an independent flag scope in the command tree. Ancestor identity
and output flags cannot configure it, even when supplied before `apps rooms`.
The parser refuses them before dispatch, and help and completion use the same
scope declaration. Managed session and team commands always emit JSON.
Continuous listening emits JSONL.

The `rooms-product` crate owns executable entry points and process tests.
Its private command module resolves Rooms-specific workspace
choices and supervises the session it starts. It is not exported by the service
library. Startup settings, readiness, and roster composition are application
front behavior. They do not require another implementation of protocol or
session state. A roster starts the same session once per identity.

`rooms-services::session::control` is an optional local view of the existing
application. Its Unix socket is inside the private workspace directory.
Filesystem access grants session administration, including private messages.
Control takes its workspace from the open peer, acquires its own journal lease
before touching the socket, and retains that lease through socket removal.
An old owner cannot unlink a replacement owner's listener during cleanup.
Application commands pass through the shared admission and execution owners.
The control view has its own failure report, not an agent-specific core notice.

The view retains conversation events through one bounded blocking disk worker.
Acknowledgements append journal records. Compaction happens at the byte limit,
and event admission reserves space for acknowledgements. Queue or storage
failure retires only this observation and records a gap. Recovery requires
explicit gap acceptance. An unclean shutdown also reports possible lost queued
events. Neither an inbox nor a model consumer can claim uninterrupted delivery
across a stopped process.
Committed changes wake long-poll readers. Continuous listening uses an opaque
change cursor, so a retained unread batch does not cause repeated polling and
serialization while a model is thinking.

The individual skill describes one peer and its active consumer. The team
skill adds roster ownership and coordination to the same procedure. Skills
contain instructions, not a second product runtime. Python remains test tooling
on this path.

## Host distribution

`rooms-build` completes the ordinary installation prefix, including its
`share/glowcap` resources, and stages `zig-out/product` for packaging. The
checkout launcher and `zig build` run commands execute the installed binary,
whose own location determines its runtime and asset paths. A compiler cache
executable is not an installation. `./glowcap` is a development launcher: it
asks the incremental build to update that installation in ReleaseSafe with
baseline CPU instructions before executing. Environment selection and the build
lease live under `.devcontainer/bin`, shared with the agent workflow through
links. Build output stays on stderr and cannot consume product stdin. An
explicit `GLOWCAP_BIN` selects an existing executable without automatic
building. `glowcap-pack` ships that Zig CLI, the private Rooms runtimes, the
iroh runtime library, prepared browser assets, and both self-contained skills.
Only `glowcap` belongs on PATH. Private runtimes resolve from `libexec` next to
the installation's `bin`. Missing components never fall back to PATH or a
checkout. Startup downloads no components and invokes no compiler. The C SDK is
a separate library/header package. Both archive profiles use one staging
mechanism with explicit manifests, checksums, provenance, and licenses. Neither
copies an unfiltered install directory. Installations and archive/checksum
directories share the same recoverable directory replacement. Handled failures
restore the previous generation. Failed restoration preserves it with a recovery
diagnostic. SIGKILL and power loss can leave that generation in staging and
require inspection.

Linux and macOS releases build on matching OS/architecture runners, using
baseline CPU instructions. Zig and Cargo must target the same platform. A
Linux devcontainer does not provide a macOS Rust toolchain or SDK, and a
cross-target Zig flag must not label a mixed artifact as a macOS package.
The release matrix owns that cross-platform build. `rooms-release` selects
ReleaseSafe and baseline CPU settings for the same product stage used by Docker
deployment. The default web listener is loopback. The directory separately retains authenticated iroh
discovery. Public HTTP exposure and operator grants are explicit choices.

The package check runs from an extracted directory with no compiler or
repository environment on the peer's PATH. It verifies relative library
loading, prepared browser serving, every packaged skill link, HTTP bootstrap, encrypted iroh, multiple
rooms and DMs, observer failure, and restart. Damaged-package fixtures hold
checksum, extraction, and dependency refusal separately from live behavior.
The check does not establish public-network reachability or macOS Gatekeeper
acceptance. The host guide names the unsigned/notarized boundary.

## Consequences and evidence

The product has no duplicate Zig Rooms participant or script orchestration. The
shared application remains the authority for Rooms behavior on host and browser.
The local command view exposes file descriptions, not file bytes. Attached views
remain necessary for file transfer.

`test/cli/rooms_session_command_cases.zig` verifies ordered repeated arguments,
scoped help, and refusal before handoff. `zig build rooms-agent-test` drives
the installed product front through individual and roster startup, multiple
rooms, private replies, unread restart, continuous consumption, and observer
storage failure. The journal unit tests cover acknowledgement replay, full
inbox recovery, and unclean shutdown.
