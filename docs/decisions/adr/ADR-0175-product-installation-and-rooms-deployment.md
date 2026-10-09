---
id: ADR-0175
status: accepted
date: 2026-09-20
tags: [cli, installation, rooms, deployment, packaging]
decision: "The Zig CLI owns verified product installation and Rooms deployment; both share the generated product inventory, and deployment builds use one immutable product snapshot with one fixed Docker stack per daemon."
supersedes: []
superseded_by: []
amends: [ADR-0150, ADR-0174]
amended_by: []
---

# ADR-0175 Product installation and Rooms deployment

## Context

The complete glowcap product includes the CLI, private Rooms runtimes,
prepared browser assets, skills, and their shared libraries. A source checkout
also needs a contributor path that reaches the same product shape. The old
deployment direction described a private shell front and mounted build output;
that split left installation, image construction, and command ownership apart.

## Decision

The Zig CLI owns `install` and `apps rooms deployment`. Installation verifies
the generated inventory, copies the complete product into a content-addressed
generation under the prefix, and atomically selects `bin/glowcap` while
preserving older generations. The checkout launcher operates the complete
`zig-out/product`, bootstrapping it through `rooms-build` only when absent.
Subsequent source edits require an explicit `rooms-build`; operating a live
session cannot depend on a compiler, build lease, or development container.
`./glowcap install` and a platform archive use the same installer. An installed
CLI never builds source.

Rooms deployment stores configuration under the XDG state path, accepts an
image tag, digest, local image ID, or a prepared Linux product for `--build`,
and saves the resolved immutable image ID. The CLI writes the managed Compose
file, preserves `docker-compose.override.yml`, and uses an OS lock on the
configuration directory. `--build` snapshots the verified product inventory
before Docker runs. The stack has one fixed set of container, network, and
volume names per Docker daemon, regardless of `--dir`. The image copies the
complete product into a distroless runtime and has no checkout or live build
mount.

The checkout launcher passes its resolved root through `GLOWCAP_CHECKOUT_ROOT`
when running its prepared product; a `GLOWCAP_BIN` override suppresses that context.
The Zig deployment command owns the resulting policy. On Linux, a checkout
`up` without an explicit image source snapshots the prepared `zig-out/product`
for its image build. Installed invocations keep their saved image selection.
On macOS, a Linux image build still requires a separately prepared Linux product.

Configuration has one owner: the selected host state directory. Moving an
existing deployment's configuration is an operator action, including its
original database credential and any relative override paths. The CLI neither
searches other directories for credentials nor imports checkout-owned state.

Reset prepares configuration and a missing image through the same path as `up`,
without first starting the old deployment. It retains a saved image unless an
explicit image source replaces it. Configuration, image preparation, and Compose
validation precede confirmation and destruction; a missing password for an
existing database remains a refusal. A prior successful `up` is not required.

## Scope (what this does not decide)

This record does not publish a release, prove a workflow run, define image
registry policy, or rewrite incompatible Rooms state. The Docker
daemon and Compose remain external prerequisites for deployment. The tracked
Compose template and Dockerfile remain under `apps/rooms/web/deploy/`.

## Alternatives Considered

- **A private shell operations front**: rejected because it duplicates command
  ownership and requires a second host runtime beside the CLI.
- **Mount checkout or build output into containers**: rejected because a
  running deployment would depend on mutable source state and could change
  underneath Docker.

## Consequences

The public entry point is `glowcap apps rooms deployment`; users do not need to
remember a deploy-directory script. Installation and deployment share the
product inventory, so missing or damaged product files fail before activation
or image construction, and unlisted build files are excluded. The deployment
state directory owns the saved image ID, Compose file, override, and database
secret, while data volumes remain fixed
Docker resources. A partially failed volume reset leaves the stack stopped
and reports the failed removal; it does not silently restart over partially
cleared state.

Child stderr is inherited, including for queries whose stdout the CLI parses.
Actions inherit both output streams. Query stdout stays bounded and separate
from product stdout; on failure it is rendered on stderr alongside the child
diagnostic and command status. Output forwarding does not wait for a newline
or process completion.

## Evidence and gate

`zig build glowcap-host-test` exercises verified installation, atomic selection,
unrelated-executable refusal, image selection, build failure preservation, and
Docker command handling without requiring a Docker daemon. It also covers
checkout image defaults and installed commands using the same host state
without checkout context. `zig build
glowcap-pack` repeats the quick installation and deployment cases from the
extracted archive. `zig build source-check` validates the ADR links and
documented build-step inventory.

## Notes

This record amends [ADR-0150](ADR-0150-operations-fronts-and-script-placement.md)
and [ADR-0174](ADR-0174-rooms-command-front-and-session-control.md). Their
historical decisions remain available; this record owns the current installation
and deployment boundary.
