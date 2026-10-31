---
type: static
description: How bindings find the C archives, how the archives are packaged, and which registry identities the packages use.
sources:
  - resource: /bindings/
  - resource: /bindings/c-abi-resolve.json
  - resource: /tools/c-abi/
---

# Finding and packaging the C archives

A published package downloads the C archives of its own version from the
GitHub release on first use. In a checkout, run `zig build`, and the bindings
find the resulting libraries under `zig-out/lib` instead.
[Releasing a version](../docs/maintaining.md#releasing-a-version) owns the
publication procedure.

The machine-readable contract is
[`c-abi-resolve.json`](c-abi-resolve.json), as decided in
[ADR-0023](../docs/decisions/adr/ADR-0023-binding-archive-resolution.md).

## Package ownership

Glowcap LLC maintains the project at
[glowcap-org/glowcap](https://github.com/glowcap-org/glowcap), with documentation
at [glowcap.org](https://glowcap.org). Every package uses Apache-2.0 and the
`abi_version` in `build.zig`, with alpha stability. Registry ownership is
established separately from GitHub organization membership.

| Registry | Identity | Published by |
| --- | --- | --- |
| crates.io | `glowcap` | `publish.yml`, as the crates.io trusted publisher. |
| PyPI | `glowcap` | `publish.yml`, as the PyPI trusted publisher. The Python import is also `glowcap`. |
| JSR | `@glowcap/*`, one package per workspace member | `publish.yml`, through the packages linked to this repository. |
| Racket catalog | `glowcap`, installing the `glowcap` collection | The maintainer, as a catalog entry pointing at the release tag. |
| GHCR | `glowcap-org/glowcap-rooms` and `glowcap-org/glowcap/devcontainer` | `release.yml` publishes and attests the Rooms image. `devcontainer-image.yml` publishes the development image. |
| npm | `@glowcap/*` | Not published. JSR's npm compatibility serves npm users and grants no npm scope. |

The [registry publishers](../docs/maintaining.md#registry-publishers) section
holds the one-time registry setup each row needs.

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

Rust resolves its libraries at build time. TypeScript, Python, and
Racket resolve shared libraries when they load. iroh is a separate
library in both cases.

Rust's optional `iroh` and `webrtc` features link shared libraries. An
application using them must ship those libraries and configure its runtime
loader, through its own executable's rpath or the platform library path.
For local runs, set `LD_LIBRARY_PATH` on Linux or `DYLD_LIBRARY_PATH` on macOS
to the SDK's `lib` directory. `GLOWCAP_LIB_DIR` selects build-time libraries
but does not configure the operating system's loader for an application.

## Rehearsing language packages

```sh
zig build bindings-package-check
```

This builds a Python source distribution and its wheel, packages the Rust
crate and Racket collection, and exercises installed consumers outside the
checkout. It also builds Rust API docs without C libraries and checks
all nine TypeScript packages with `deno publish --dry-run`. Nothing is uploaded.
The bindings CI phase runs this rehearsal before qualification.
Each package carries the repository's Apache license text. The rehearsal
compares the packaged copy with its source.

The C-library checks use the locally built SDK. The same script with
`--registry <version>` installs a published version from each registry in a
fresh consumer with no local SDK, and `publish.yml` runs it after each upload.
Rust documentation on docs.rs uses all features and skips C-library
resolution, following [docs.rs's build contract](https://docs.rs/about/builds).

JSR is the TypeScript publication path. Its npm compatibility is separate
from publishing packages directly to npm. The browser Wasm artifact remains
an explicit application build input, as the [browser guide](ts/web/README.md)
describes. Racket installs as the `glowcap` collection, with imports such as
`(require glowcap/glowcap glowcap/glowcap-tcp)`.

### Download behavior

A binding decides whether to download from where it runs. Outside a checkout,
a cold cache downloads the binding's version unless `GLOWCAP_SKIP_DOWNLOAD=1`
is set. Inside a checkout, found by `build.zig` beside
`include/glowcap_ocapn.h`, the binding uses `zig-out/lib` and downloads only
when `GLOWCAP_DOWNLOAD=1` is set, so a tree ahead of its release attempts no
network.

Downloads require HTTPS through redirects and a matching entry in `SHA256SUMS`.
Extraction accepts regular files under `lib/` only. Links and path traversal are refused.
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

Product archives remain available when a release proof fails. To recheck those
exact installed products with a corrected harness, run
`gh workflow run release.yml --ref BRANCH -f recheck_run=RUN_ID`.
This checks the four host products and builds and exercises their two Linux
container images without recompiling, checking source packages, or publishing.
A complete release rehearsal leaves `recheck_run` empty.
[Releasing a version](../docs/maintaining.md#releasing-a-version) describes
the tag push that publishes the archives.
