# Changelog

Every release lists what changed for people using glowcap, in the form
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) describes. The
release notes on each [GitHub release](https://github.com/glowcap-org/glowcap/releases)
open with that version's section, so a release needs its section here first.
glowcap is alpha software, and a minor or patch version can change APIs, ABIs,
and storage formats before 1.0.

## [Unreleased]

## [0.1.1] - 2026-10-31

### Added

- Rust, Python, TypeScript, and Racket packages are published from the release
  tag: `glowcap` on crates.io and PyPI, `@glowcap/*` on JSR, and `glowcap` in
  the Racket catalog. Each downloads the C libraries of its version on first
  use and verifies them against the release checksums.
- Release notes carry a platform download table, verification and install
  steps, a package install section, and this changelog's entry for the version.
- The Rooms container image carries a signed publication attestation that
  `gh attestation verify` checks against this repository.
- The C SDK archive ships a README with a runnable C example.

### Changed

- A binding outside a checkout downloads its own version unless
  `GLOWCAP_SKIP_DOWNLOAD` is set. Inside a checkout it uses `zig-out` and
  downloads only with `GLOWCAP_DOWNLOAD`. The contract's `releases_published`
  switch is gone.
- Release archives omit empty directories, and their README and provenance
  links resolve from an extracted archive.

### Fixed

- A release whose archive or image job was skipped is refused instead of
  publishing nothing. Publication can be recovered from the signed tag's
  original run without rebuilding or moving the tag.

## [0.1.0] - 2026-10-31

### Added

- The first tagged release: CapTP 1.0 over Syrup with signed sessions, the
  Zig library and C ABI, the Rust, TypeScript, Python, and Racket bindings,
  Loam transactional storage with durable actors, the `glowcap` CLI, and the
  Rooms application with its container image. [What ships](docs/shipped.md)
  describes the release in full.

[Unreleased]: https://github.com/glowcap-org/glowcap/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/glowcap-org/glowcap/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/glowcap-org/glowcap/releases/tag/v0.1.0
