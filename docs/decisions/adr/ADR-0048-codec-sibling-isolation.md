---
id: ADR-0048
status: accepted
date: 2026-06-11
tags: [architecture, build, modules, codec]
decision: Each sibling wire codec is its own internal build.zig module (`syrup`, `capnp`) over a shared `framing` verdict module, so one codec naming another codec's files is a compile error. The codec root (`mod.zig`, `dispatch.zig`, `registry.zig`) is the only surface that imports both.
supersedes: []
superseded_by: []
---

# ADR-0048 Codec sibling isolation as import law

## Context

ADR-0040 made the layer DAG compile-enforced: one internal module per layer,
with an explicit one-way import table. That law stops a codec from reaching session or engine, but it cannot see inside
a layer. `syrup/` and `capnp/` both lived in the one `codec` module, so
`syrup/decode.zig` importing `../capnp/wire.zig` would have compiled. The
codec-plurality posture (ADR-0003) treats the two codecs as independent fillers
of a slot resolved through the registry/dispatch seam, and the open registry
(ADR-0026) promises a third codec costs nothing the built-ins did not. Both
assume sibling codecs share only the codec-neutral model and the framing
verdict, which only convention held. The build system's module tables can hold
it.

## Decision

- **One module per sibling codec.** `build.zig` creates internal modules rooted
  at `src/ocapn/codec/syrup/mod.zig` and `src/ocapn/codec/capnp/mod.zig`. Each
  imports `foundation`, `model`, and `framing` and nothing else. A codec naming
  the other's files fails to compile.
- **`framing` is a shared module.** The codec-verdict vocabulary
  (`framing.Prefix`) is rooted at `src/ocapn/codec/framing.zig` and imported by
  both codecs, by the codec root, and by nothing above the codec layer directly.
  The engine and netlayer reach it as `codec.dispatch.framing`.
- **The codec root is the one bilingual surface.** `mod.zig` re-exports both
  codecs under the unchanged public names. `dispatch.zig` and `registry.zig`
  import both to route by `model.CodecId`. A consumer-supplied codec still
  arrives through `pub const glowcap_codecs` in the root file (ADR-0026) and is
  equally invisible to the built-ins.
- **All three build graphs carry the same wiring** (host, cross-compile
  full-library, cross-compile sans-io core), so the boundary holds on every
  target `zig build check` compiles.

## Scope (what this does not decide)

- The public `glowcap.ocapn.codec` namespace is unchanged. Module names are
  internal vocabulary (ADR-0040).
- Which codecs exist and how they negotiate. ADR-0003, ADR-0026.

## Notes

A relative import from `syrup` to `capnp`, or the reverse, fails with
`file exists in modules 'capnp' and 'syrup'`, because the compiler refuses one
file belonging to two modules.
