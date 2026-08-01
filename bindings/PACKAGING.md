# Finding and publishing the C archives

The bindings are not published yet. In a checkout, run `zig build`; the
bindings find the resulting libraries under `zig-out/lib`.

This page describes the archive lookup and the release switch for packagers.
The machine-readable contract is
[`c-abi-resolve.json`](c-abi-resolve.json), as decided in
[ADR-0077](../docs/decisions/adr/ADR-0077-publishable-c-abi-resolve.md).

## Finding the archives

Every binding uses the same order:

1. `PANCAKE_LIB_DIR`, when set;
2. the versioned download cache;
3. `zig-out/lib` when running from a checkout;
4. the operating system's library search on Unix.

Windows does not use a bare DLL name because its search order can load a
library from an unintended directory. Use `PANCAKE_LIB_DIR` or a populated
cache there.

Rust resolves its static libraries at build time. TypeScript, Python, and
Racket resolve shared libraries when they load. iroh remains a separate
library in both cases.

### Download behavior

`releases_published` in `c-abi-resolve.json` is currently false. A cold cache
therefore does not contact the network unless `PANCAKE_DOWNLOAD=1` is set.
After releases are enabled, `PANCAKE_SKIP_DOWNLOAD=1` disables fetching.

Downloads require HTTPS and a matching entry in `SHA256SUMS`. Extraction
accepts regular files under `lib/` only; links and path traversal are refused.
`PANCAKE_STRICT=1` turns a network or tool failure into a hard error instead of
continuing to the local fallbacks.

`PANCAKE_RELEASE_BASE_URL` points at a different release host.
`PANCAKE_ALLOW_INSECURE=1` permits HTTP for a controlled test mirror; normal
loads reject it.

The cache root is chosen from `PANCAKE_CACHE_DIR`, then `XDG_CACHE_HOME`, then
the platform's user cache directory. The ABI version and normalized target
select the directory underneath it.

Target names match `zig build release-pack`, such as `x86_64-linux` and
`aarch64-macos`. The normalization rules live in
[`../tools/c-abi/c-abi-host-aliases.json`](../tools/c-abi/c-abi-host-aliases.json).
Rust begins with `CARGO_CFG_TARGET_ARCH` and `CARGO_CFG_TARGET_OS`; the other
bindings normalize common aliases such as `amd64`, `arm64`, and `darwin`.

Linux and macOS are the current packaging targets. Windows needs
`PANCAKE_LIB_DIR` or an in-tree build until its runtime and release path exist.

## Building release archives

```sh
zig build release-pack
```

This writes checksummed, target-specific archives under `zig-out/release/`.
The tarballs contain regular files rather than library symlinks.

The release workflow uses the same archive set. A manual workflow run builds
artifacts without publishing a GitHub release.

## Publishing C archives: flip checklist

Do not change `releases_published` until the corresponding release assets can
be downloaded.

1. Run `zig build release-pack` for every published target.
2. Set `releases_published` to true in `c-abi-resolve.json`.
3. Copy the updated contract to every path in its `package_copies` list.
4. Tag `v{abi_version}`, matching `include/pancake_ocapn.h`.
5. Push the tag and confirm the release workflow publishes the tarballs and
   `SHA256SUMS`.
6. Test a cold-cache install against the live release URL.

Before that switch, `PANCAKE_DOWNLOAD=1` can rehearse the download path against
staged assets.
