---
id: ADR-0077
status: accepted
date: 2026-07-12
tags: [bindings, c-abi, packaging, public-surface]
decision: "Language bindings resolve the C ABI archives through a publishable cascade (configure env, abi-versioned download cache, optional in-tree zig-out, then OS search) whose machine contract is `c-abi-resolve.json` shipped inside each package. Download is language-native (no monorepo `tools/` dependency). The operator script `tools/c-abi/fetch-c-abi.sh` remains for humans and CI only."
supersedes: []
superseded_by: []
---

# ADR-0077 Publishable C-ABI archive resolution

## Context

Bindings will ship to language package registries (crates.io, PyPI, npm/JSR,
the Racket catalog) and may later live in separate source repos. A consumer of
a published package has no Zig checkout, no `zig-out/lib`, and no
`include/pancake_ocapn.h`. Collapsing download into a monorepo shell script
(`tools/c-abi/fetch-c-abi.sh`) that every binding shells out to is DRY for in-tree
dogfoods and wrong for that publish surface: the script is not in the package
tarball, `/bin/sh` is not a Windows contract, and Deno's permission model
treats spawn as a distinct grant from network.

Industry packages that depend on prebuilt natives (esbuild, swc, napi-rs
addons) embed the download in the package and pin the artifact version from
package-local metadata.

## Decision

1. **`bindings/c-abi-resolve.json` is the machine contract** for URL templates,
   cache layout, markers, and `abi_version`. Identical copies ship inside each
   binding package path listed in `package_copies`; `tools/check/source_check.zig` fails
   if any copy drifts from the canonical file or from `PANCAKE_VERSION_*` in
   `include/pancake_ocapn.h`. Env truthy values are the fixed set `1` / `true` /
   `yes` in each loader (not a contract field). Env *names* live in
   `bindings/PACKAGING.md`. Host target triples for release-pack are `{arch}-{os}`
   with zig names; `tools/c-abi/c-abi-host-aliases.json` lists host aliases and is
   wired into `source_check` (every alias must appear in the non-cargo ports).
   Rust uses `CARGO_CFG_TARGET_ARCH` / `CARGO_CFG_TARGET_OS`, which already emit
   those names; Python, TypeScript, Racket, and `tools/c-abi/fetch-c-abi.sh` normalize
   aliases (`amd64`/`x64`, `arm64`, `darwin`/`macosx`). Release-pack OS list is
   linux + macos until a Windows matrix leg exists.

2. **Cascade order** (configure first, never download on that path):
   `PANCAKE_LIB_DIR`, then abi-versioned cache, then optional discovered pancake
   checkout's `zig-out/lib`, then bare library name / link-search fallthrough.

3. **Download is language-native** inside each binding (Rust `build.rs`, Python
   urllib+tarfile, TypeScript curl/tar with Deno permission degradation, Racket
   curl/tar). Soft-fail when no release exists yet (in-tree dogfoods use
   `zig-out`); `PANCAKE_STRICT=1` fail-closes. `tools/c-abi/fetch-c-abi.sh` is an
   **operator** tool only: bindings must not require it.

4. **Version pin:** prefer `include/pancake_ocapn.h` when a pancake checkout is
   discoverable (in-tree dogfood); otherwise use the package-shipped
   `abi_version` from the contract. Cache base prefers `PANCAKE_CACHE_DIR`, then
   `$XDG_CACHE_HOME/pancake/c-abi`, then `~/.cache/pancake/c-abi`, then the
   process temp dir.

5. **Native-ABI download hygiene** (required of every fetch port):
   - HTTPS-only release base (`PANCAKE_ALLOW_INSECURE=1` is the only escape).
   - Require `SHA256SUMS` and verify the exact tarball entry before extract
     (never install unverified bytes; do not rely on `--ignore-missing`).
   - Extract only the `lib/` prefix; reject path traversal, absolute paths, and
     every member that is not a regular file or a directory (the zip-slip
     class, and symlinks and hardlinks with it). Ports that read `tar -tv`
     output run it under `LC_ALL=C`, accept only the GNU and BSD column
     layouts, and refuse a listing they cannot parse rather than guess where
     the member name starts. The name they check is the whole parsed name: a
     member whose name contains tar's own `" -> "` link separator must not be
     checked as a prefix of itself.
   - Cap transfer size (`max_tarball_bytes` in the contract).
   - Prefer absolute `dlopen`/`LoadLibrary` paths; refuse bare DLL names on
     Windows (search-order plant risk). Python, TypeScript, and Racket all
     refuse; `tools/check/source_check.zig` requires the refuse message in each
     shared-lib loader.

## Consequences

- A published binding can resolve natives with only network + cache + the
  shipped contract.
- Separate binding repos stay viable: they carry their own contract copy and
  native fetch; they do not need the Zig tree at consumer install time.
- Per-binding fetch ports will drift in small ways; the gate holds the
  formulas (tarball name, base URL, abi version, package copies, checksum and
  extract hygiene fields, per-loader cache-marker roles, symlink/traversal
  rejection before extract, Windows bare-DLL refusal on shared-lib ports,
  host-target aliases wired from `tools/c-abi/c-abi-host-aliases.json`,
  `tools/c-abi/c-abi-resolve-cases.json` URL/cache/`want_fetch` oracle,
  `user_agent` embedding `abi_version`, package-ship of the contract across
  Python/TS/Racket/Rust, and hard-fail `require_https`/`require_checksum` at
  load including Rust and the operator script) so the resolve cascade cannot silently
  diverge from `zig build release-pack`. Rust parses the contract with
  `serde_json` in `build.rs` (no hand-rolled scanner). Unifying the five
  language-native download *implementations* into one shared runtime remains
  deferred: language constraints (Deno permissions, Python stdlib tar, Rust
  build.rs, Racket FFI load time) make a shared library the wrong shape;
  `tools/c-abi/c-abi-resolve-cases.json` is the drift apex instead.
- Windows release-pack is blocked today: `release-pack` is a Unix `sh` script,
  `linkIrohSidecar` hardcodes `libpancake_iroh_sidecar.a`, TCP still uses
  posix paths that fail `x86_64-windows-gnu` cross-builds, and there is no
  IOCP completion backend. Until those land, `release_pack_names.oses`
  excludes windows and consumers use `PANCAKE_LIB_DIR` or in-tree `zig-out`.
- A tagged archive release is accepted only after `check.yml` succeeds for the
  exact release commit. The release workflow gives every final tarball and the
  combined `SHA256SUMS` a GitHub artifact attestation before publishing them;
  consumers can verify that build provenance independently of the checksum
  file. Per-target hash pins inside packages, Forgejo mirror workflows, and
  language-registry publication remain separate operational surfaces.
- `releases_published` in `c-abi-resolve.json` is the prerelease valve for
  hosted C archives: when false, loaders and `tools/c-abi/fetch-c-abi.sh` skip the
  release download unless `PANCAKE_DOWNLOAD=1`, and the release workflow skips
  `gh release create`. Hygiene and security refusals (non-HTTPS without a typed
  escape, checksum miss, zip-slip / link members) always fail closed;
  `PANCAKE_STRICT` only hardens soft network/tooling failures.
  `zig build c-abi-extract-check` (part of `check`) runs each port's own
  validator against hostile fixtures in tree: zip-slip, symlink, an owner
  field shaped like a date to move a naive parser's column guess, and a
  regular file whose name contains tar's `" -> "` separator. Flipping
  `releases_published` to true is the public commit for that
  surface only; see the flip checklist in `bindings/PACKAGING.md`.
- Vendoring platform wheels/cdylibs inside each package remains a future
  packaging optimization; this ADR is the find/download contract either way.
  Pinning per-target hashes _inside_ the package (stronger than the attested,
  same-host `SHA256SUMS`) becomes useful once package-registry releases have a
  separately reviewed update path for those pins.
