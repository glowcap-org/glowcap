---
description: "Zig pancake architecture guardrails: codec-neutral model, authoritative session, sync no-I/O core."
globs: src/**/*.zig, test/**/*.zig, bench/**/*.zig, examples/**/*.zig, examples/**/*.c, include/**/*.h, build.zig, README.md, docs/**/*.md, AGENTS.md
---

# pancake — Architecture Guardrails

## Authority runs one direction

Default `1.0` answers to actual Goblins behavior. `pancake-next` tracks current
OCapN direction, including recorded consensus and live proposals, not only text
already merged into the draft. Before deleting next behavior as non-spec,
update the conformance submodules and inspect the meeting record plus the open
issue or PR that owns it. Preserve conflicting proposals as explicit variants
until consensus selects one; do not blend them into an unsourced wire format.
Bindings remain dogfoods, never semantic oracles.

**Read the draft before writing wire behavior, not only before deleting it.**
The trigger is any change to what pancake puts on the wire, and `conformance/
ocapn-spec/upstream/draft-specifications/` usually answers outright. Designing
the choreography first and checking after is how an unsourced wire format gets
written: it compiles, it passes the tests written alongside it, and it is
wrong in a way only a partner can see. A behavior the draft already specifies
is not a design question.

```text
Frame -> Codec view -> Session state -> Outgoing Message -> Codec -> Frame
```

**Session state owns authority.** Codecs parse and render bytes; they do not
decide whether a reference, answer, export, import, or release is valid.
**If a change moves authority downward into codec or adapter code, stop and
redesign.** When a concern fits no layer above, give it to the layer that owns
the decision, never the layer where the symptom appeared.

Export positions are minted only by the session's allocator
(`Peer.exportNextObject`), and the C Host exposes opaque Host identities rather
than export positions. A counter kept outside the session eventually collides
with that same counter's resolver and bootstrap exports and silently aliases a
live object.

## The core stays sync and no-I/O

The portable core takes no sockets, no hidden scheduler, no background tasks, no
`std.Io` in protocol modules, and no adapter policy inside codecs, session, or
engine. Adapters may use `std.Io`, transports, callbacks, and host scheduling,
but never invent semantics, lifecycle, ownership, or policy absent from shared
Zig authority. Bindings adapt syntax and resource idioms and drive shared state
machines; if one needs a second state machine, fix the core or C ABI first.
The C ABI and bindings are plumbing: they marshal values, execute core-selected
effects, and project exact outcomes into each runtime's native error and
lifetime idioms. Protocol decisions, application/business rules, retry policy,
and recovery policy do not belong there.

A nonblocking I/O operation's cancel edge interrupts the effect and retires its
worker before freeing operation state. Abandoning a result while blocked I/O
continues is not cancellation.

CapTP is transport-agnostic and never names a transport. A netlayer is a locator
transport symbol (`tcp`, `keyed-tcp`, `noise-tcp`, `keyed-relay`, `inproc`,
`iroh`, `webrtc`, `onion`), and socket and stream code lives in transport
residents. `keyed-tcp` and `noise-tcp` are their own symbols reusing `tcp`
sockets, not second CapTP stacks; `noise-tcp`'s sealed channel (ADR-0107) is
run by the core Host that owns the session, never by the resident, which is
why the blocking tier refuses the symbol. The channel itself is
`foundation.sealed.SealedChannel`, homed like `foundation.Spill` because both
stream tiers run it: the byte-fed Host boxes one per sealed session, and the
completion-loop tier composes the same machine in the sealing backend adapter
(`net.noise_completion`), which finishes the handshake before the loop sees
the dial connected and answers `verifiedChannelKey` — the same realizer seam
iroh uses. `noise-relay` is that adapter over the keyed-relay pipe
(`net.NoiseRelayLoop`) on the completion dial side. Registered accepts use the
keyed-relay resident's sealed profile and the byte-fed Host. Browser wasm can
run that same Host channel, but the shipped rendezvous path is still cleartext
`keyed-relay`; Rooms DMs use WebRTC.

## Not every shipped netlayer is deployable

The split is not obvious from the code. The human page is
`site/content/transports.smd` and the consequences are in `docs/boundaries.md`.

| Symbol | Peer proof | Channel | Verdict |
| --- | --- | --- | --- |
| `tcp` | none; the designator is an address | cleartext | testing and Goblins interop only |
| `inproc` | none, and nothing to prove | in-process pipes | tests only |
| `keyed-tcp` | none; key designator is a dial target only | cleartext | trusted network only |
| `noise-tcp` | Noise_XK between the CapTP peers; completing it proves the exact durable key in both directions (ADR-0107) | end-to-end encrypted records | production through the native Host tiers, C driver loop, and native bindings; `BlockingSession` refuses it |
| `keyed-relay` | none; key designator is a dial target only | cleartext `ws://` | trusted relay and network only |
| `noise-relay` | Noise_XK between the CapTP peers, over the relay pipe; the relay forwards ciphertext (ADR-0107) | end-to-end encrypted records | production through the relay provider package, generic C driver, and native bindings; browser wasm does not compose this provider |
| `onion` | Tor's rendezvous handshake on the dialing side, nothing on the accepting side | encrypted, anonymized Tor circuit | proven live against Goblins in both directions and the complete portable upstream suite; blocking resident, provider package, native Zig completion loop, and every native binding ship |
| `webrtc` | identity authorized by signaling | DTLS DataChannel | production |
| `iroh` | QUIC remote node id, the one realizer proof in the tree | encrypted QUIC | production |

**`onion` is the only symbol here the OCapN draft standardizes**, and the only
one upstream Goblins ships, so it is where a pancake peer and a Goblins vat meet
on ground neither invented. Its designator stays an address: the service id names
the rendezvous service, not the CapTP peer, and an onion locator carries no hints
because the pinned Goblins refuses a hinted one (ADR-0108). `zig build
goblins-onion` is the meeting the symbol exists for, both directions over real
circuits. `zig build ocapn-conformance-onion` passes all portable upstream
modules plus the strict abort probe through the upstream onion netlayer. That
netlayer returns from `ADD_ONION` before descriptor publication, so the dedicated
harness self-dials through its upstream SOCKS client and consumes the accepted
probe before exposing the locator; the barrier establishes readiness without
replacing upstream connect, accept, or CapTP behavior. `driver.HostRuntime` polls an onion
connection like any other socket, the onion archive installs into the generic C
driver, and `net.OnionLoop` composes the platform completion backend without
adding transport knowledge to the loop.

**`tcp` is not an ordinary default.** The OCapN draft requires a netlayer to
keep a session insertable only by its participants, upstream Goblins ships no
TCP netlayer, and the upstream suite's own is `tcp-testing-only`. Reach for
`iroh` when adding a default, an example, or a demo; pick `tcp` only to reach a
peer that speaks nothing else, and say in the same breath that it is cleartext.

A fresh session key signs each hello, so it proves session continuity and never
durable identity. Only the code that authenticated the end-to-end channel may
report a proved peer.

## Names carry three things

A name that indexes a table is three things: the namespace it belongs to, whose
namespace that is, and when it meant what it meant. A Zig type carries the
first. A key of `u64` or `[]const u8` carries only the first, and the other two
live in whatever the author was thinking.

That gap is the costliest bug class this core has had, and every instance was
one missing dimension: a near _or a far_ from one session naming an object on
another, a projection settling an answer position the partner had released and
reasked, two gifters reusing one gift id. **Both directions of that first one
are live**, so when you close a position rule on one side of the wire, write
down why the other side does not need the same rule, or give it the same rule.

Every fix that held added a dimension: disjoint ranges, identity stamps, domain
separation, a token that dies with its row. **Every fix that had to be taken
back tried to _police_ the collision instead**, and policing a name the protocol
lets a peer choose refuses correct peers.

So prefer a key that carries its own dimensions, a distinct type or a composite
naming the owner. Where a key stays bare, `zig build source-check` requires it to
answer both questions in `tools/check/source_check/namespaces.zig`, in both
directions.

## Layer Ownership

Where code goes. `build.zig`'s `layer_table` and `archive_table` are the
authority for module edges and the archive set, `docs/architecture.md` is the
readable tour, and `source-check` holds this list against `src/` in both
directions.

- `foundation`: bytes, IDs, frame ownership, and the `Spill` where a stream's
  not-yet-consumed bytes wait. The `Spill` lives this low because both
  stream-reading tiers need one and neither imports the other.
- `ocapn/`: the OCapN / CapTP protocol itself, the four layers that _are_ the
  protocol. Everything else adds none. Reached as `pancake.ocapn.<layer>`.
  - `ocapn/model`: codec-neutral semantic types.
  - `ocapn/codec`: encode and decode, plus borrowed semantic views.
  - `ocapn/session`: validation and the authoritative tables.
  - `ocapn/engine`: the caller-owned `Peer`, `step`, inbound dispatch, outbound
    drain.
- `actors`: Goblins-shaped local objects and a sync, no-I/O `Vat` (spawn,
  near-call `$`, eventual-send `<-`, promises) above the engine, adding no CapTP
  semantics the engine lacks. Also owns opt-in local time-travel (ADR-0060),
  which is local-only and never wire state.
- `persistent`: a sharp leaf of persistent immutable collections, one
  refcounted-HAMT `PersistentMap` (ADR-0061) so a persistent actor's functional
  `become` is O(log n). Pure, no-I/O, imports nothing, off the public `pancake`
  namespace, reached only by opt-in persistent actors.
- `diagnostics`: the vendor-neutral typed record and bounded journal for a
  failure whose last deterministic return recipient has gone (ADR-0115).
  Mutable storage belongs to an explicit Context, Host, or driver; the module
  owns no global journal, logging backend, protocol outcome, or fatal policy.
- `net`: the one place `std.Io` enters. Folds the one parser over a stream and
  realizes netlayer residents over byte streams. Not part of the no-I/O core.
- `driver/core` (`driver_core`): the sans-io serve core the driver stands on.
  The vat serve loop `Served` and its verbs, the shared vocabulary, turn-time
  `spawnAt`, stateless GC, and the byte-fed multi-session CapTP host core
  `Host`. It is `core = true`, so **`arch-check` bans I/O here exactly as in
  `engine`, and that ban is what keeps a socket from creeping back into the
  serve core** (ADR-0072). A byte-fed consumer (the `libpancake_host` C ABI, a
  browser) drives a `Served` or a `Host` directly, net-free. The `Host` is split
  across sibling files by responsibility, each presenting its verbs as `Host`'s
  own through decl aliases; `host.zig` keeps the state, the byte pump, the serve
  hooks, and the application verbs, and **its alias table is the index**.
  `host_pump.zig` is private to the directory (`source-check` holds this), and a
  helper made `pub` for a sibling says so where it is declared.
- `driver`: the native application surface above `driver_core`, `actors`, and
  `net`, composing the sans-io core with I/O. `BlockingSession` is the
  no-router single-connection tier; `driver.Session` and `driver.Server` are
  views onto an owning `driver.HostRuntime` (ADR-0090), so the front door redeems
  handoffs; `driver.Bridge` plus `completion.Loop` is the scale embedding of the
  same core (ADR-0068, ADR-0072, ADR-0076). Language bindings drive
  `driver_core.Host` through `libpancake_host` rather than rebuilding a Zig Host
  type. Adds no CapTP semantics. It also owns the `drawSessionSecret` entropy
  boundary and the transport constructors, the members that must stay above the
  core's I/O ban.
- `c_abi/`: the public C ABI family, grouped the way `src/ocapn/` groups the
  protocol core. It ships as composable archives that **share types by _layout_,
  not symbols** (ADR-0055, ADR-0059), each exporting only its own
  `pancake_<family>_*` family. Signatures and constants are reflected from Zig
  while header prose lives in `tools/gen/header/*.zig`, so a C-contract change
  edits both and then runs the `gen-*` step.
  - `c_abi/shared` (`c_abi_shared`): archive-neutral C layouts and mechanics.
    `locator.zig` is POD vocabulary only; `locator_adapter.zig` projects the
    OCapN model without turning provider archives into OCapN symbol consumers.
    **Declares no `export fn`**, so every archive reuses it without inheriting
    another's exports.
  - `c_abi/ocapn` (`c_abi`): `libpancake_ocapn`, C-shaped only. Every handle
    frees through exactly one `pancake_*_release`; a `*_close` is a shutdown
    lever and never frees, which `source-check` holds in the generated headers.
  - `c_abi/host` (`c_abi_host`): `libpancake_host`, the byte-fed host tier
    (ADR-0072). An embedder owning its own loop, sockets, and entropy drives a
    full multi-session CapTP Host with bytes, and the host's own effects surface
    as actions, so publish, fetch, send, vows, projections, and the full
    three-party handoff run from C with no socket.
  - `c_abi/driver` (`c_abi_driver`): `libpancake_driver`, the native loop
    archive (ADR-0112). Exports only the `pancake_driver_*` family and adopts a
    quiescent Host from `libpancake_host` through
    `pancake_driver_take_host`: a stepping `driver.HostRuntime` behind one
    readiness descriptor and one event queue, with the standalone provider ABI
    as the transport seam. A new loop starts with zero transports; one thread
    drives one loop; dial and accept handshakes advance across steps
    (`HostRuntime.startDial`, `HostRuntime.startAcceptWire`), so loops
    on one thread can dial each other and a stalled connector cannot park
    the step.
    `ProviderRegistry` alone validates and adapts stream/multiplexed tables and
    holds package leases. Listener locator projection and canonicalization use
    one callback ABI across both execution models; their incompatible I/O
    ownership stays separate. `source-check` holds this split.
    Generic driver and binding loop modules name no concrete transport. Product
    composition loads provider archives; each archive owns every profile it
    advertises, its realization policy, and its lifecycle.
    Bindings reject only unsafe or lossy ABI marshalling; the C ABI owns
    semantic argument validity and bindings translate its diagnostic.
  - `c_abi/wasm` (`c_abi_wasm`): the browser binding's freestanding `wasm32`
    entry root (ADR-0070). Forces the `pancake_*` and `pancake_host_*` families
    into one loadable module and adds the two JS-to-wasm linear-memory
    primitives. Adds no CapTP surface; sits outside the layer DAG.
  - `c_abi/net_transport/tcp` (`c_abi_net_transport_tcp`): the TCP transport
    archive, exporting only `pancake_tcp_*`. It owns the complete `tcp`,
    `keyed-tcp`, and `noise-tcp` provider package together with the low-level
    framed connection API; the provider lease is the native lifetime authority.
  - `c_abi/net_transport`: the grouping directory for transport sidecars and
    injected residents, holding no source of its own. Each child is its own
    `.graph = false` layer outside the layer DAG because its artifact boundary
    is not expressible as a DAG edge.
    - `c_abi/net_transport/inproc` (`c_abi_net_transport_inproc`): the
      in-process archive, exporting only `pancake_inproc_*`.
    - `c_abi/net_transport/iroh` (`c_abi_net_transport_iroh`): the iroh archive,
      exporting only `pancake_iroh_*`. `arch-check` still claims the directory
      for file coverage and the I/O bans.
    - `c_abi/net_transport/webrtc` (`c_abi_net_transport_webrtc`): the WebRTC
      archive (ADR-0089), exporting only `pancake_webrtc_*`. Alone among the
      transports it imports `c_abi_shared` and not `net`, because its surface is
      an endpoint readiness fd plus peer creation, signaling, non-blocking
      try-I/O, and close. **A bare locator carries no signaling authority, so
      the resident exposes no fake address `Netlayer`.**
- `oracle`: canonical CapTP scenario drivers, the observable-trace reference the
  Zig oracle tests compare against. Its own module off the public `pancake`
  namespace, imported by tests and consumed by no binding, because the bindings
  prove the C ABI by dogfood rather than oracle traces. Not on the runtime path.
  (The top-level `conformance/` tree is unrelated: it holds external authority.)

## CapTP vocabulary (ADR-0079)

Kept here, not in human first-read docs.

| Name | Is |
| --- | --- |
| `Host` / `PancakeHost` / binding `Host` | multi-session CapTP product; owns `engine.Node` |
| `engine.Node` | sans-io handoff router |
| binding `Session` | one-partner app object, a view onto a `driver_core.HostSession` under a Host |
| `driver.Session` | the same contract natively, a view onto an owning `driver.HostRuntime` (ADR-0090) |
| `driver.BlockingSession` | the no-router single-connection tier, the one place `Settled.give` surfaces, and the only tier a transport with no pollable descriptor can ride — so it does not collapse into `HostRuntime` |
| Goblins `mycapn` | two roles: product maps to Host; router tables map to `engine.Node` |

Application-level binding `Node` and `Connection` are deleted, and `net.Connection` is the byte
stream only. There is no multi-session "node" alias for `PancakeHost` and no
`driver.Connection`.
