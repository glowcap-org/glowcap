# Changelog

Every release lists what changed for people using glowcap, in the form
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) describes. The
release notes on each [GitHub release](https://github.com/glowcap-org/glowcap/releases)
open with that version's section, so a release needs its section here first.
glowcap is alpha software, and a minor or patch version can change APIs, ABIs,
and storage formats before 1.0.
Releases before 0.1.7 are in the
[earlier changelog](docs/history/CHANGELOG.md).

## [Unreleased]

### Changed

- Dependencies move to their current releases. The development container takes Rust 1.100, Node 26.13.1, Bun 1.4.5, Playwright 1.65.1, uv 0.13.9, and ruff 0.17.6, so rebuild it. The Rooms server image takes the current Distroless base, the relay's TLS build takes Mbed TLS 4.3.0, and the iroh transport takes iroh 1.5. The CLI's REPL takes libvaxis fixes for key parsing, wrapping, and terminal restore.

### Fixed

- Match release image metadata to the Docker or OCI manifest format when publishing the multi-platform image.
- Reuse the authenticated release lookup when validating installers on shared CI hosts.
- Use the browser's login on the Rooms server's own page and explain when Settings cannot read a server reply.
- Stop a Racket call on the driver loop from waiting forever when its answer arrives just as it starts waiting.
- Stop a Racket server on the driver loop from spinning a core while a session sits idle.

### Security

- The Python binding's `rendezvous` extra requires websockets 17.4 or later, the first release that limits how many frames one relay message may span.

## [0.1.8] - 2026-11-20

This release includes the [changes prepared for 0.1.7](docs/history/0.1.7/changes/CHANGELOG.md).
Read the [migration notes](docs/history/0.1.7/migration/CHANGELOG.md) before
upgrading a client, provider, or Rooms deployment with saved state.

### Changed

- Open glowcap rooms and ocapnviz from the website's Apps menu and project footer.

### Fixed

- Verify the installed glowcap executable before publishing the host archives.

## [0.1.7] - 2026-11-19

Read the [migration notes](docs/history/0.1.7/migration/CHANGELOG.md) before
upgrading a client, provider, or Rooms deployment with saved state. Browse
the [features and fixes](docs/history/0.1.7/changes/CHANGELOG.md), including
the WebRTC reopen fix, and the [earlier changes](docs/history/0.1.7/CHANGELOG.md)
in this release.

[Unreleased]: https://github.com/glowcap-org/glowcap/compare/v0.1.8...HEAD
[0.1.8]: https://github.com/glowcap-org/glowcap/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/glowcap-org/glowcap/compare/v0.1.6...v0.1.7
