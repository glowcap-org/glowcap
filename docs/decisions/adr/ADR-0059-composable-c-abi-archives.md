---
id: ADR-0059
status: accepted
date: 2026-06-13
tags: [architecture, build, c-abi, packaging, netlayer, transport, bindings]
decision: "The C ABI ships as composable archives linked a la carte: shared OCapN vocabulary, one Host application surface, one generic driver, and self-contained transport provider packages. Archives export only their own family and share values by header layout. There is no umbrella library or export-less net archive."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0096, ADR-0112, ADR-0122, ADR-0123]
---

# ADR-0059 Composable C ABI archives

## Context

A single umbrella library made every consumer carry every transport and made
optional sidecars part of the core link contract. It also encouraged bindings to
treat one artifact as the owner of protocol values, Host behavior, driver
execution, and transport policy, concerns with different dependencies and
deployment owners.

The C boundary needs one shared vocabulary. Locators, sturdyrefs, frames,
arguments, contexts, error codes, and provider tables have one layout in every
archive. Sharing that layout does not require a common implementation library or
a second runtime owner.

## Decision

The public C surface is a set of symbol-disjoint archives:

| Package | Ownership |
| --- | --- |
| `libglowcap_ocapn` | Shared OCapN values, locator and sturdyref operations, URI helpers, contexts, and frame ownership. |
| `libglowcap_host` | The byte-fed, multi-session CapTP application surface. |
| `libglowcap_driver` | The generic native loop over an adopted Host and installed provider packages. |
| `libglowcap_net_transport_tcp` | The complete `tcp`, `keyed-tcp`, and `noise-tcp` provider package, plus low-level TCP endpoints. |
| `libglowcap_net_transport_relay` | The complete `keyed-relay` and `noise-relay` provider package. |
| Other transport archives | One self-contained package for in-process, onion, iroh, or WebRTC integration. |

Each archive exports only its own `glowcap_<family>_*` symbols and owns its own
diagnostic slot. Headers share fixed-layout declarations through
`glowcap_ocapn.h` and `glowcap_transport_provider.h`. Private Zig modules are
compiled into the archive that uses them and remain local symbols. There is no
`libglowcap` umbrella and no `libglowcap_net` archive with no public contract.

The driver starts with zero transports. A transport archive returns one
`GlowcapTransportProvider` package containing every profile it owns. The driver
copies the generic execution tables after retaining the package lease. It does
not name a concrete transport or reconstruct transport-specific locators. A
provider owns dialing, listening, readiness, locator canonicalization, and
transport policy. The Host owns CapTP state and sealed-channel policy selected
from provider metadata.

`GlowcapLocatorView` is the archive-neutral locator seam. OCapN owns its
semantics and construction, while a provider can borrow the fixed view without
linking an OCapN implementation into its own behavior. `GlowcapSturdyRef`
remains a separate value because its swiss bytes carry authority a locator does
not.

ABI structures keep `abi_version` and `struct_size` validation at version 1, so
malformed crossings fail closed. Prerelease preserves no aliases and no
compatibility history.

## Composition

A byte-fed embedder links `ocapn + host` and whichever low-level transport
archives it drives itself. A native-loop embedder links `ocapn + host + driver`
and the provider archives it installs. Optional iroh and WebRTC archives bring
their own sidecars and remain outside the default build when their toolchains
are unavailable.

Provider retain and release callbacks are the transport lifetime authority.
The driver may outlive the constructor handle because registration holds the
package lease until all copied callbacks, listeners, and connections retire.
Nothing relies on load order, global transport registration, or a binding-owned
mirror of the provider set.

Archives that share opaque Host and actor owners are built together from the
same compilation inputs. Private layout compatibility across different builds
is not supported. Matching public ABI fingerprints alone do not establish it.
Within that composition, callbacks cannot use a function-table address as a
protocol identity or exchange unqualified Zig error ordinals. Opaque local
delivery uses a stable adapter protocol token and checks its actual Vat owner.
Handlers catch errors in their producing compilation and carry immutable
diagnostic text. A private error-domain identity permits typed near-call errors
only within that compilation. Foreign failures preserve their text for queued
and served answers. Clone callbacks express their sole failure as null.

## Consequences

- A new transport adds one package and one provider entry set without changing
  the driver or generic bindings.
- A transport archive may own several symbols when they are profiles over one
  implementation, as TCP and relay do.
- Private implementation can evolve with Zig because it is not an internal C
  ABI. Only exported families and fixed shared layouts cross artifacts.
- Consumers pay only for the archives they choose. Linking two self-contained
  packages may duplicate private code, but does not add runtime coupling or an
  unsupported internal ABI.
- Generated headers, archive inventory checks, symbol-family checks, and live C
  composition examples hold the package boundaries.

## Alternatives Considered

**Keep one umbrella library.** Rejected: optional transports and sidecars
become dependencies of every consumer, and one artifact obscures ownership.

**Publish a common `libglowcap_net` implementation archive.** Rejected: the
archive would have no public consumer contract, and exporting private Zig
internals as a C ABI would freeze an extra boundary only to avoid some local
code duplication. Provider packages already give the driver its runtime seam.

**Teach the driver each concrete transport.** Rejected: every new
transport would change the generic archive and every binding. Provider metadata
and execution tables keep concrete policy behind the owning package.

**Let each binding implement transport execution.** Rejected for native
archive-backed transports: it duplicates readiness, lifecycle, and locator
policy in every runtime. Bindings keep byte-fed adapters for channels their
runtime owns, including browser Web APIs.

## Evidence

`zig build check` verifies generated headers, archive and symbol inventories,
provider layout, static composition, and C driver scenarios. Binding checks
consume the archives as independent clients. The iroh, WebRTC, relay, and onion
provider proofs exercise the same generic driver seam with their real runtime
requirements.

ADR-0096 owns the Host-scoped capability surface. ADR-0112 owns driver adoption,
provider execution, and package lifetime.
