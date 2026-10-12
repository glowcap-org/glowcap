---
id: ADR-0175
status: accepted
date: 2026-09-20
tags: [cli, installation, rooms, deployment, packaging]
decision: "The Zig CLI owns verified product installation and Rooms deployment. Both share the generated product inventory, and deployment builds use one immutable product snapshot with data targets resolved from Compose."
supersedes: []
superseded_by: []
amends: [ADR-0150, ADR-0174]
amended_by: []
---

# ADR-0175 Product installation and Rooms deployment

## Context

The complete glowcap product includes the CLI, private Rooms runtimes, prepared
browser assets, skills, and their shared libraries. A source checkout also needs
a contributor path that reaches the same product shape. An earlier deployment
direction used a private shell front and mounted build output, which left
installation, image construction, and command ownership apart.

## Decision

The Zig CLI owns `install` and `apps rooms deployment`. Installation verifies
the generated inventory, copies the complete product into a content-addressed
generation under the prefix, and atomically selects `bin/glowcap` while
preserving older generations. The checkout launcher operates the complete
`zig-out/product`, bootstrapping it through `rooms-release` when absent.
The release preset invokes the shared `rooms-build` graph with ReleaseSafe and
baseline CPU settings. Ordinary commands keep their prepared product.
Operating a live session cannot depend on a compiler, build lease, or development container.
`./glowcap install` and a platform archive use the same installer. An installed
CLI never builds source.

Rooms deployment stores configuration under the XDG state path, accepts an image
tag, digest, local image ID, or a prepared Linux product for `--build`, and
saves the resolved immutable image ID. The CLI writes the managed Compose file,
preserves `docker-compose.override.yml`, and uses an OS lock on the
configuration directory. `--build` snapshots the verified product inventory
before Docker runs. The default stack shares container, network, and volume
names per Docker daemon. `--dir` selects configuration. Operator overrides can
select separate resources. Inspection and reset resolve the service mounts
through Compose and refuse external or ambiguous destruction targets. The image
copies the complete product into a distroless runtime and has no checkout or
live build mount.

`up` replaces services when their selected image or configuration changes and
preserves healthy, unchanged services. `restart` restarts the saved deployment
without selecting another image or removing data, waits for health, and prints
the restored capabilities. Reset describes the data and authority it destroys
before asking for confirmation.

The checkout launcher passes its resolved root through `GLOWCAP_CHECKOUT_ROOT`
when running its prepared product. A `GLOWCAP_BIN` override suppresses that context.
The Zig deployment command owns the resulting policy. On Linux, a checkout
`up` or `reset` without an explicit image source first prepares the current
source through `rooms-release`, then snapshots `zig-out/product` for its image
build. The validated command requests preparation through the checkout launcher
and replays its original arguments into the fresh executable. Release metadata
declares support for that preparation contract. The launcher treats a product
without it as incomplete. Zig's incremental build owns freshness, including uncommitted edits.
Explicit image sources and inspection commands skip source preparation when
the host product exists. Installed invocations keep their saved image selection.
On macOS, a Linux image build still requires a separately prepared Linux product.

Configuration has one owner: the selected host state directory. Moving an
existing deployment's configuration is an operator action, including its
original database credential and any relative override paths. The CLI neither
searches other directories for credentials nor imports checkout-owned state.

Reset prepares configuration and a missing image through the same path as `up`,
without first starting the old deployment. It selects an image by the same
checkout or installed policy as `up`. Configuration, image preparation, and Compose
validation precede confirmation and destruction. A missing password for an
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

The public entry point is `glowcap apps rooms deployment`. Users need no
deploy-directory script. Installation and deployment share the product
inventory, so missing or damaged product files fail before activation or image
construction, and unlisted build files are excluded. The deployment state
directory owns the saved image ID, Compose file, override, and database secret.
Compose's resolved mounts select the Docker data volumes. A partially failed
volume reset leaves the stack stopped and reports the failed removal. It does
not silently restart over partially cleared state.

Child stderr is inherited, including for queries whose stdout the CLI parses.
Actions inherit both output streams. Query stdout stays bounded and separate
from product stdout. On failure it is rendered on stderr alongside the child
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

`zig build infrastructure-check` exercises checkout preparation, explicit image
sources, help, macOS host dispatch, and build failure before command dispatch.

## Notes

This record amends [ADR-0150](ADR-0150-operations-fronts-and-script-placement.md)
and [ADR-0174](ADR-0174-rooms-command-front-and-session-control.md). Their
historical decisions remain available. This record owns the current installation
and deployment boundary.
