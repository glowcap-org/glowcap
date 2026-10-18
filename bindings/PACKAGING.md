---
type: static
description: How bindings find the C archives in a checkout and how the archives are packaged for publishing.
sources:
  - resource: /bindings/
  - resource: /bindings/c-abi-resolve.json
  - resource: /tools/c-abi/
---

# Finding and publishing the C archives

No binding package is published. In a checkout, run `zig build`. The
bindings find the resulting libraries under `zig-out/lib`.

The machine-readable contract is
[`c-abi-resolve.json`](c-abi-resolve.json), as decided in
[ADR-0077](../docs/decisions/adr/ADR-0077-publishable-c-abi-resolve.md).

## Finding the archives

Every binding uses the same order:

1. `GLOWCAP_LIB_DIR`, when set
2. the versioned download cache
3. `zig-out/lib` when running from a checkout
4. the operating system's library search on Unix.

Windows does not use a bare DLL name, because its search order can load a
library from an unintended directory. Packaging targets Linux and macOS, so
Windows needs `GLOWCAP_LIB_DIR` or an in-tree build until its runtime and
release path exist.

Rust resolves its static libraries at build time. TypeScript, Python, and
Racket resolve shared libraries when they load. iroh is a separate
library in both cases.

### Download behavior

`releases_published` in `c-abi-resolve.json` is false. A cold cache
therefore does not contact the network unless `GLOWCAP_DOWNLOAD=1` is set.
Once releases are enabled, `GLOWCAP_SKIP_DOWNLOAD=1` disables fetching.

Downloads require HTTPS and a matching entry in `SHA256SUMS`. Extraction
accepts regular files under `lib/` only. Links and path traversal are refused.
`GLOWCAP_STRICT=1` turns a network or tool failure into a hard error instead of
continuing to the local fallbacks.

`GLOWCAP_RELEASE_BASE_URL` points at a different release host.
`GLOWCAP_ALLOW_INSECURE=1` permits HTTP for a controlled test mirror. Normal
loads reject it.

The cache root comes from `GLOWCAP_CACHE_DIR`, then `XDG_CACHE_HOME`, then
the platform's user cache directory. The ABI version and normalized target
select the directory underneath it.

Target names match `zig build release-pack`, such as `x86_64-linux` and
`aarch64-macos`. The normalization rules live in
[`../tools/c-abi/c-abi-host-aliases.json`](../tools/c-abi/c-abi-host-aliases.json).
Rust begins with `CARGO_CFG_TARGET_ARCH` and `CARGO_CFG_TARGET_OS`. The other
bindings normalize common aliases such as `amd64`, `arm64`, and `darwin`.

## Building release archives

```sh
zig build -Doptimize=ReleaseSafe release-pack -Dcpu=baseline
```

This writes checksummed archives for the current target under
`zig-out/release/`.

**Replacing the output.** The tarball and checksums replace the contents of
that directory as one unit, so keep downloads somewhere else. If the build
fails in a way it handles, it restores the previous contents. If restoring
fails too, the error names the staging directory it kept. Power loss is not
handled.

**Build requirements.**

- `release-pack` refuses Debug mode, so a bare invocation cannot publish
  development binaries. Other Release modes are available for an embedding
  that documents a size or speed choice.
- It requires baseline CPU instructions and a build that matches the running
  host's OS, architecture, and ABI, so a package named by its architecture
  does not depend on CPU features of the machine that built it.

**What goes in.** The archive table in `build.zig` is the release manifest.
Packaging copies only those libraries and their public headers, by name, so
leftover files in `zig-out` cannot add a target or an internal artifact. Each
tarball also carries the repository's `PROVENANCE.md` and its license files. The
tarballs contain regular files and no library symlinks.

**What it checks.** Before returning, the step extracts the tarball outside
the checkout. It then builds and runs:

- one C program for every self-contained static archive
- one C program across the packaged shared libraries, which also loads the
  iroh companion through them

It also compares the extracted `PROVENANCE.md` byte for byte with the one in
the source tree.

The [glowcap product package](../apps/rooms/host.md) is a separate download
for CLI and Rooms users. It includes private runtimes, prepared browser assets,
and individual/team skills without C development archives or headers.
The same release matrix builds and verifies both products.

The optional relay archive is self-contained: its pinned, namespaced Mbed TLS
client is linked privately into `libglowcap_net_transport_relay`, so a binding
discovers and distributes no second runtime library. Packages that omit the
relay archive carry no TLS artifact or dependency.

The release workflow uses the same archive set. A manual run builds artifacts
without publishing a GitHub release.

## Publishing C archives

`releases_published` controls whether consumers try the hosted archive URL. It
does not authorize the release workflow to create those archives. Change it
only after the assets can be downloaded and verified.

1. Run `zig build -Doptimize=ReleaseSafe release-pack -Dcpu=baseline` for every published
   target.
2. Push the release commit and require its exact SHA to complete `check.yml`
   successfully, including its macOS runtime jobs.
3. Tag `v{abi_version}`, matching `include/glowcap_ocapn.h`. The release
   workflow independently queries the successful exact-SHA check before it
   builds archives.
4. Push the tag and confirm the release workflow publishes the tarballs and
   `SHA256SUMS`, and records GitHub artifact attestations for both. Confirm each
   archive contains the tagged `PROVENANCE.md` disclosure.
5. Download each archive, verify `SHA256SUMS`, then verify its artifact
   attestation with `gh attestation verify --repo OWNER/REPO <archive>`.
6. Set `releases_published` to true in `c-abi-resolve.json`, then copy the
   updated contract to every path in its `package_copies` list.
7. Push that consumer-enablement commit and require `check.yml` to pass for its
   exact SHA.
8. Test a cold-cache install against the live release URL without
   `GLOWCAP_DOWNLOAD=1`.

Before that switch, `GLOWCAP_DOWNLOAD=1` can rehearse the download path against
staged assets.
