---
id: ADR-0059
status: accepted
date: 2026-06-13
tags: [
  architecture,
  build,
  c-abi,
  public-surface,
  packaging,
  netlayer,
  transport,
  bindings,
  minimality,
]
decision: "The C ABI ships as composable per-family archives linked à la carte (`libpancake_ocapn` (sans-io peer + shared vocabulary), `libpancake_net` (net-core base), and one archive per transport (`libpancake_net_transport_{tcp,inproc,iroh}`)) each exporting only its `pancake_<family>_*` symbols and its own last-error reader, sharing core types by header layout; the single `libpancake` / `pancake.h` umbrella is dropped. The packaging contract (archive set, export families, the build-declared archive DAG, and per-archive headers) is fixed and composition-model-agnostic. It ships now with Model A (self-contained companion archives that embed their lower layers as local symbols, the proven ADR-0055 mechanism); Model B (a base that exports an internal linkable net-core seam so transports carry no duplicate) is the committed end state, reached by an internal-only migration that changes no header, no consumer link recipe, and no exported family. Within that packaging, a symbol earns its place on the surface only by a domain-specific minimality bar derived from the OCapN/CapTP operation set (a distinct protocol op, the primitive a binding consumes, or a named easy-path constructor over an explicit one) and the structural invariants that bound it (constructor-twin completeness, one error channel per archive, one freeing verb per handle) are gated in `tools/check/meta_check.zig`."
supersedes: []
superseded_by: []
---

# ADR-0059 Composable C ABI archives

## Context

The C ABI shipped as one artifact.
[ADR-0040](ADR-0040-layer-modules-as-import-law.md) made each `src/` layer an
internal build module but pinned its scope: _"One `libpancake` artifact still
ships; the modules are compilation structure, not packaging or versioning
units."_ The project value **boring public surface** named the artifacts
explicitly: `libpancake.a`, `libpancake.so`, `pancake.h`.
[ADR-0055](ADR-0055-iroh-netlayer-sidecar.md) opened the first crack: the iroh
transport links a Rust sidecar, so it could not fold into the pure-Zig core and
shipped as a symbol-disjoint _companion_ (`libpancake_iroh`).
[ADR-0062](ADR-0062-one-connect-over-a-netlayer-slice.md) unified the dialer but
left its own note: a libpancake-level locator dialer is "a separate, larger move
left for later."

The destination this ADR serves is the à-la-carte FFI surface: a consumer: in
any language: links the protocol it needs and the transports it chooses, and
the pieces compose as naturally as Zig modules do, the way a C program that
includes two headers and links two archives composes. That extends to surfaces
the C ABI does not expose yet (the actor vat, the async driver, the completion
loop): a consumer who prefers pancake's threading model over its host runtime's
should be able to adopt it. Those surfaces are net-new ABI and are out of this
ADR's _implementation_ scope (see Scope), but the packaging contract is designed
to receive them without reshaping.

This reopens ADR-0040's scope note on purpose, and it reshapes: does not
abandon, **boring public surface**: each archive is itself boring (opaque
handles, fixed-width discriminants, `ptr+len` views, explicit release), and the
surface becomes a small, declared _set_ of them. It engages **explicit over
implicit** (the archive dependency DAG is declared, not implied by what happens
to link), **performance is correctness pressure** (the duplication cost of the
chosen mechanism is measured below, not asserted), and **make the correct path
the easy path** (the per-archive header a consumer includes names exactly the
symbols the archive it links exports).

Two measurements set the engineering frame. First, code size: the entire
ReleaseSmall library: every layer, the full C ABI, `tcp` and `inproc` included
is **352 KB** of code; the iroh Rust sidecar alone is **36 MB**. Second,
symbol linkage: of the archive's symbols, exactly **72 are global** (`T`): all
the `pancake_*` C ABI exports (and **748 are local** (`t`)) every internal
layer function (`net.*`, `engine.*`, `Connection`, `FrameStream`, …). Zig marks
non-`export` functions local by design, so they are _not_ a cross-archive ABI.
That single fact decides the shape of the no-duplication end state below: it
cannot be a visibility flag; it must be a deliberate exported seam.

## Decision

### The packaging contract (fixed, composition-model-agnostic)

The C ABI is a set of composable archives. Each archive is built in both static
(`.a`) and shared (`.so`) form, ships a header naming only the family it
exports, and shares core types with the others _by layout_ (a transport header
`#include`s `pancake_ocapn.h`). The single `libpancake` / `pancake.h` umbrella
is dropped; there is no "everything" artifact.

| Archive | Exported family | I/O |
| --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------ |
| `libpancake_ocapn` | `pancake_abi_version`, `pancake_context_*`, `pancake_managed_frame_release`, `pancake_event_release`, `pancake_peer_*`, `pancake_any_event_release`, `pancake_uri_*` / `pancake_locator_*`, `pancake_last_error` / `pancake_clear_last_error` | none (sans-io) |
| `libpancake_net` | none in Phase 1 (net-core base; see Migration) | `std.Io` |
| `libpancake_net_transport_tcp` | `pancake_tcp_*`, `pancake_tcp_last_error` / `_clear` | `std.Io` |
| `libpancake_net_transport_inproc` | `pancake_inproc_*`, `pancake_inproc_last_error` / `_clear` | `std.Io` |
| `libpancake_net_transport_iroh` | `pancake_iroh_*` (exists; + Rust sidecar) | `std.Io` + sidecar |

`libpancake_ocapn` owns the shared vocabulary: the C-visible types
(`PancakeContext`, `PancakeFrame`, `PancakeManagedFrame`, `PancakeReference`,
`PancakeArgument`, `PancakeEvent`, …), the return codes, the codec selector,
and is the universal base every consumer links. It stays sans-io: net-core lives
in `libpancake_net`, never here.

Each transport archive is self-contained at the symbol level: it carries its own
per-thread last-error slot and reads it through its own
`pancake_<family>_last_error`, exactly as `libpancake_net_transport_iroh` does
today. It shares **no runtime symbol** with `libpancake_ocapn`; it cooperates
with the peer purely through the `PancakeContext` pointer the consumer creates
with `pancake_context_new` and through type layout. This is a surface change
from the monolith: `tcp` and `inproc` errors, formerly read through the one
`pancake_last_error`, are now read through `pancake_tcp_last_error` /
`pancake_inproc_last_error`.

### The archive DAG, declared once

`build.zig` gains an `archive_table`: a sibling to the existing `layer_table`,
whose rows name each archive, its C ABI module root (the source of its export
family), the layer modules it draws on, and its **dependency edges** (which
other archives a consumer links alongside it). The dependency DAG is:

```
net_transport_{tcp,inproc,iroh}  ──▶  net  ──▶  ocapn
```

A consumer using tcp links `ocapn + net + tcp`. The table is the one authority:
the build generates every artifact and every header from it, and
`tools/check/meta_check.zig` consumes it to verify each declared archive is built,
headered, and indexed, and each declared edge is real: the same "tables carry
the edges the code uses" law ADR-0040 established for layers.

### Model A is the shipping mechanism

Model A generalizes the proven ADR-0055 companion: each archive's C ABI module
`@import`s the layer modules it needs, compiling them in as **local** symbols,
and exports only its `pancake_<family>_*`. Splitting `tcp` and `inproc` out of
the core into companions: each importing `net`, `model`, and `c_abi_shared` and
exporting its own family and last-error reader: is the whole of the Phase-1
mechanism. `libpancake_ocapn` keeps the peer/context/frame/uri families.

Under Model A `libpancake_net` exports no symbol any other archive references:
the transports embed net-core locally, so the linker's archive-member selection
(static) or `--gc-sections` drops `libpancake_net` from a final binary at zero
cost. It is present in the contract: built, headered, and named in the link
recipe: so the consumer's link line is **identical** to the one Model B needs.
The documented recipe (and pancake's own bindings) link/load the full DAG chain
in both models, so the A-to-B migration is invisible to them.

The measurements above justify shipping A first: a full static link of
`ocapn + net + tcp + iroh` carries well under ~1 MB of duplicated Zig versus
Model B's theoretical minimum: under 3% of the iroh sidecar, and noise beside
any real application. Size-sensitive consumers get `-Doptimize=ReleaseSmall` and
`--gc-sections` guidance in the docs.

### The surface is minimal by a derived bar, gated

Composable archives say _how_ the C ABI is packaged; they do not say whether a
particular archive exports the right functions. Generic FFI guidance settles
representation: opaque handles, fixed-width discriminants, `ptr + len` views,
explicit release: but not whether ninety exported functions are the right
ninety, or whether three of them are one function wearing three names. pancake's
surface is therefore held to a domain-specific minimality bar derived from the
OCapN/CapTP operation set it must reach. A symbol earns its place only by one of
three tests, and nothing else:

1. **Distinct protocol operation**: it performs a CapTP/OCapN move no other
   export performs (`send_deliver`, `register_export`, `start_session`, the
   frame/stream-input trio, `step`, `take_outbound`, and the rest). Remove it
   and a protocol move becomes unreachable.
2. **The primitive a binding consumes**: the function the bindings actually
   call (`poll_event` and the raw frame it returns, `peek_event`, the
   per-archive `last_error`, the locator accessors).
3. **A named easy path over an explicit one**: a constructor that pins the
   common case so it stays a one-liner (`pancake_peer_new` is
   `pancake_peer_new_negotiated` at the authenticated v1.0 defaults). The
   explicit form stays the escape hatch; the preset is the easy path.

The structural invariants that bound the surface are mechanical, so the gate
holds them rather than prose. `tools/check/meta_check.zig`'s `checkCAbiSurfaceShape`
(with the pre-existing `checkAbiFreeingVerb`) requires `_new`/`_new_in`
constructor-twin completeness, exactly one `last_error`/`clear_last_error` pair
per archive, and one `*_release` freeing verb per handle, so a careless addition
that breaks the shape fails `zig build check`.

Two judgment calls are deliberate, not drift. `raw_open` stays a _separate
named_ constructor: an unauthenticated peer the bindings' own tests and several
real-socket harnesses build on: so the footgun never hides behind a flag on the
safe path; and the generic `poll_event` stays beside the typed polls because it
is the raw-frame primitive the bindings consume. Collapsing the named peer
constructors into one config-struct call is rejected: it would turn the
unauthenticated `raw_open` policy into a field a caller can set by accident and
tax the common authenticated case. Minimality is the floor, never a reason to
make the correct path harder.

## Migration (Model A to Model B)

Model B is the committed end state, not a someday: it carries no duplicate
net-core, the property "fit together as naturally as Zig" most literally wants.
Because internal layer symbols are local (measured: 748 local vs 72 global), B
is **not** a visibility flag: it is a deliberate exported seam, designed here
so the migration is a contained, internal-only `build.zig`-and-transport change.

- **The seam.** `libpancake_net` grows an internal, `export`-ed C-ABI seam,
  the internal net seam (the double underscore marks it internal, not public, the way
  the iroh sidecar's private `pancake_iroh_sidecar_*` seam does): covering the
  net-core operations transports use (`Connection` / `FrameStream` framing,
  `Spill`, the netlayer `Contract` dial/bind). It is a real linkable contract,
  not a mangled-name gamble, so it survives a toolchain bump.
- **The transports thin.** Each transport's C ABI stops `@import`ing `net` for
  those operations and calls the seam externs instead. Net-core's authoritative
  copy then lives once, in `libpancake_net`; the transports become thin shims
  over it. Net-core symbols become default-visibility in the base and hidden
  elsewhere.
- **What does not change.** The archive set, every public header, every
  `pancake_<family>_*` export, the consumer link recipe (`ocapn + net + tcp`),
  and the bindings' documented load chain are all identical before and after.
  The migration touches the `archive_table` wiring, the transport C ABI source,
  and symbol visibility: nothing a consumer or a header sees.

This is why the contract is B-shaped from day one (the rejected Path 2 in
Alternatives): `libpancake_net` is first-class immediately so the migration
never adds an archive to anyone's link line.

## Scope (what this does not decide)

- **Phase 1 is the implementation scope of this ADR:** repackage the _existing_
  surface into `ocapn` / `net` / `net_transport_{tcp,inproc,iroh}` with Model A.
  No new behavior and no new export family beyond splitting the per-transport
  last-error readers out of the shared `pancake_last_error`.
- **Model B is designed here, built later.** The seam above is not implemented
  in Phase 1; `libpancake_net` is inert under Model A.
- **The new surfaces are reserved, not built.** The actor vat, the async driver,
  and the completion loop have no C ABI today. This ADR reserves their archive
  slots in the contract: a bare-vat archive (built by ADR-0071, later retired
  when ADR-0072's `libpancake_driver` subsumed it), `libpancake_driver`,
  `libpancake_net_completion`: so they slot in as later phases without
  reshaping the DAG, but it does not design their families. The Rust example
  that chooses FFI iroh versus native Rust iroh without a shipped cost is a
  later phase that rides on Phase 1's standalone
  `libpancake_net_transport_iroh`.
- **No locator-dialer C ABI.** The per-transport C ABI stays below the locator
  seam (ADR-0062); a libpancake-level locator dialer remains out of scope.

## Alternatives Considered

- **Keep the single `libpancake` / `pancake.h` umbrella** (as the default, or as
  a convenience beside the granular set): rejected. À-la-carte composition is
  the goal, and an umbrella reintroduces the monolith the vision rejects. A pure
  link-group convenience could return later without touching the contract.
- **Model B first:** rejected. The duplication B removes is sub-megabyte and
  negligible beside the 36 MB sidecar (measured), while B is invasive and novel.
  Ship the proven mechanism; reach B by the internal migration above.
- **Minimal Model-A contract now, add `libpancake_net` at B time (Path 2):**
  rejected. It drifts the consumer link recipe at migration: exactly the
  half-measure the B-shaped contract (Path 1) avoids by making `libpancake_net`
  first-class from the first commit.
- **Export internal layer symbols (no seam):** rejected on evidence. Zig marks
  non-`export` functions local (748 local vs 72 global), and gives no stable
  cross-archive name for them, so a no-duplication base requires the deliberate
  exported seam, not a flag.

## Consequences

- **Build.** `build.zig` gains `archive_table`; the artifact and header
  generation loop over it. `irohAbiModule` generalizes into a per-archive module
  factory; `tcp` and `inproc` C ABI modules are carved out of `c_abi/core/` into
  their own roots under the `c_abi/net_transport/` grouping directory, beside
  `c_abi/net_transport/iroh/`.
- **Headers.** `pancake.h` is replaced by `pancake_ocapn.h` (the vocabulary
  base) plus one header per _exported_ archive, each named to match its archive
  1:1 (`libpancake_<suffix>` ⇔ `pancake_<suffix>.h`):
  `pancake_net_transport_tcp.h`, `pancake_net_transport_inproc.h`, and
  `pancake_net_transport_iroh.h`. The inert `libpancake_net` base exports
  nothing and ships no header. Transport headers `#include "pancake_ocapn.h"`
  for the shared vocabulary. Header generation is per C ABI module:
  `gen-header-ocapn` and `gen-header-net-transport-{tcp,inproc,iroh}`, each with
  a `-check` variant that runs as part of the gate.
- **Gate.** `archive_table` is held honest at comptime in `build.zig`: the
  artifact and header loop is generated from it, and a comptime check fails the
  build if an archive's dependency edge names no archive in the table: so every
  declared archive is built and headered or the build does not compile. A
  composed static-link example links `ocapn + tcp + inproc` into one binary
  (`examples/c/compose_transports.c`, run by `zig build examples`) and asserts
  no duplicate-symbol collision and that each family resolves: the standing
  proof of Model-A composition. Per-archive `gen-header-*-check` steps keep each
  header honest against its module on the `check` path, and
  `checkCAbiSurfaceShape` holds the minimality invariants (constructor twins,
  one error channel per archive, one freeing verb per handle) so the surface
  cannot bloat unnoticed.
- **Bindings.** All four bindings (`deno`, `python`, `rust`, `racket`) load the
  `ocapn` + transport `.so` chain instead of one `libpancake.so`; their internal
  FFI loaders split accordingly. `zig build bindings` stays the dogfood gate.
- **Docs.** `docs/architecture.md` (§ C ABI Contract, § Examples As Contract),
  the **boring public surface** value in `.agents/rules/project-values.md`,
  ADR-0040's scope note, `docs/shipped.md`, and `docs/roadmap.md` are realigned
  to the composable-set surface. The C examples link the composed set.

## Forward compatibility

`archive_table` is the reserved seam for the later phases: a new surface adds an
archive row and a `pancake_<family>_*` family, and never mutates an existing
archive's exports, so a consumer that linked `ocapn + tcp` keeps working
verbatim as `actors`, `driver`, and `net_completion` arrive. The
The internal net seam in `libpancake_net` is the reserved internal ABI for the
Model-A-to-B migration.

## Notes

- Builds directly on [ADR-0040](ADR-0040-layer-modules-as-import-law.md): the
  module-per-layer mechanism is the scaffolding the archive matrix is generated
  from; this ADR reopens only that ADR's "one artifact ships" scope note.
- Generalizes [ADR-0055](ADR-0055-iroh-netlayer-sidecar.md) from the iroh
  companion to every transport.
- Resolves the "libpancake-level move left for later" flagged in
  [ADR-0062](ADR-0062-one-connect-over-a-netlayer-slice.md) § Scope.
