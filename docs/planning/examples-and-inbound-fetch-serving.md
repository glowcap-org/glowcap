# Examples port + inbound-`'fetch` serving

Status: in flight — Phase 1 landed (inbound-`'fetch` serving half + examples
01–02 + the handshake→bootstrap-fetch conformance scenario); examples 03–08
pending (Phase 2). This doc is the plan of record for two coupled pieces of work:

1. Bringing the Rust repo's eight `docs/examples/` chapters into this tree as
   runnable Zig example programs.
2. Building the inbound-`'fetch` **serving** (responder) half in the Zig
   runtime — the surface chapters 02 and 08 need, which Zig ships only as an
   initiator today. The examples are the forcing function: write the consumer
   story first, then build what makes it pass.

The canonical Rust runtime is the single-source-of-truth (Invariant 12); the
serving half here is a faithful mirror of Rust's already-accepted substrate, not
a new design.

## The examples

The Rust "examples" are the eight narrative chapters at `docs/examples/` in the
Rust repo, each prose plus compiling snippets, drift-defended by
`examples_compile.rs`. They are all in-process (`paired`, no netlayer); the only
"async" is that Rust's `Peer::send`/`recv` are `async`. The Zig equivalents are
**sync**, so the port is simpler, not blocked.

| # | Chapter | Zig surface | Ports now? |
| --- | --- | --- | --- |
| 01 | Call a remote method | `paired`, deliver/resolve, references, `op:gc-exports` | yes |
| 02 | Look up a service by name | **inbound-`'fetch` serving** (new) + initiator | needs serving half |
| 03 | Pass a reference along | `Argument.reference` in a deliver | yes |
| 04 | Skip the round-trip | `runtime.pipeline` against an unresolved answer | yes |
| 05 | Do three things at once | multi-hop pipeline decomposition | yes |
| 06 | Poke me when it's ready | `op:listen` + relayed resolution | yes |
| 07 | Speak Goblins | `pairedWithOffers` / V1_0 wire profile + resolver-callback | yes |
| 08 | Enliven a sturdyref | `runtime.sturdyref` initiator + **inbound-`'fetch` serving** | needs serving half |

Sturdyref enliven (08) on the wire **is** a `'fetch` to the partner's bootstrap,
so once `'fetch` serving exists, 08's responder is automatic — no enliven-specific
serving code, and ADR-0012 is unchanged.

### Form factor

Runnable Zig programs under `examples/zig/NN_name.zig`, one per chapter, each
carrying the chapter's narrative in a `//!` header and inline `//` comments so
narrative and compiling code move together (drift-defended by *running* in
`zig build examples` → `check`, which is strictly stronger than Rust's
snippet-only compile test). An `examples/README.md` index mirrors the chapter
table. No separate prose `.md` corpus and no snippet-extraction harness (YAGNI).

## The gate: ADR-0006 amendment

Zig `ADR-0006` is `accepted` and explicitly scopes serving inbound `'fetch`
**out** ("the session keeps no swissnum→export table and synthesizes no
resolution"). Per repo discipline (ADRs flip to accepted *before* code is built
against them), the amendment lands first: move serving from § Scope into
§ Decision, mirroring Rust ADR-0006's accepted responder substrate. Only
ADR-0006 changes.

## Serving half (mirrors Rust)

| Layer | Rust (canonical, exists) | Zig (to build) |
| --- | --- | --- |
| Session | `BootstrapTable` (swissnum→export), `register`/`lookup` | `BootstrapTable` on `Session`; `registerBootstrapCap`, `bootstrapLookup` |
| Runtime | `bootstrap.rs`: `pending_bootstrap_request` + `resolve_for_swissnum` | new `src/runtime/bootstrap.zig` |
| Dispatch | recognition branch in `inbound.rs` before `record_recv` | branch in `dispatchOwnedFrameInner`, after pipelining, before event append |
| Peer | `register_bootstrap_cap` | `Peer.registerBootstrapCap` |
| Factories | `with_p1/p2_swissnums` | post-construction `registerBootstrapCap` (add `pairedWithSwissnums` only if call sites get noisy) |

The session stays a passive table owner (lookup only); the runtime recognizes
the shape and synthesizes the reply. No bootstrap dispatch inside
`recordRecv` — same separation Rust keeps.

### Dispatch flow (responder)

1. Host registers `(swissnum → export_id)` via `Peer.registerBootstrapCap`
   (config-time, no wire). Export 0 already installed at `transitionToOpen`.
2. Inbound `op:deliver` reaches `dispatchOwnedFrameInner`. After the pipelining
   branch, `bootstrap.pendingBootstrapRequest` structurally matches: target
   export 0, `args = [Symbol "fetch", Bytes swissnum]`, reply route from
   `answer` vs `resolve_me_desc`.
3. On match: `recordRecv` runs, `Event.deliver` is emitted (observability,
   mirroring Rust's `emit_event_for_inbound`), then
   `bootstrap.resolveForSwissnum` is pushed onto `pending_send`.
4. `step` encodes the reply on the outbound pass.
5. Non-matching delivers fall through unchanged.

### Wire shape + reply routes

Request: `<op:deliver <desc:export 0> ['fetch swiss-number] answer-pos resolve-me-desc?>`

| Profile | Partner sent | Responder reply |
| --- | --- | --- |
| PreSpec / pancake-canonical | `answer` set, no `resolve_me_desc` | `op:resolve`: `Fulfill(Near)` or `Break("unknown swissnum")` |
| Goblins V1.0 | `resolve_me_desc` = resolver import | `op:deliver` to resolver: `['fulfill ref]` / `['break err]` (reuses `encodeResolverCallback`) |

Both routes are already understood by Zig's initiator matcher
(`fetch.tryMatchFetchOutcome`), so the responder is symmetric with code that
exists.

### Error handling

- Unknown swissnum → `Break("unknown swissnum")` resolution (not a session
  error) — matches Rust.
- Malformed `'fetch` (wrong args) → structural match fails → ordinary deliver
  event, the application's concern.
- `BootstrapTable` is host-populated config-time state, not partner-driven, so
  no resource cap (consistent with ADR-0025's partner-driven-only cap policy).

## Conformance + drift

- New scenario `runHandshakeThenBootstrapFetch` in `src/conformance/mod.zig`
  (paired peers, register a cap on the responder, initiator fetches, assert the
  responder **auto**-resolves) plus a golden trace under `test/oracles/`, run by
  `oracle-check`. Parallels Rust's `handshake_then_bootstrap_fetch_then_canonical`.
- De-manualize `test/runtime/fetch_test.zig` and `test/runtime/sturdyref_test.zig`:
  drop the hand-rolled responder `sendCopying(.resolve …)`, assert auto-synthesis.
- Examples drift-defended by running in `check`.
- README "Not Implemented" loses inbound-`'fetch` serving and inbound
  sturdyref-enliven serving.

## Out of scope

- Production netlayers / real transport (the examples stay in-process).
- A networked example (would force a netlayer) — a separate follow-up.
- Serving anything beyond bootstrap `'fetch` (handoff `deposit/withdraw-gift`
  stay under ADR-0009).
