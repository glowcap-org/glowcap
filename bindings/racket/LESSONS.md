# pancake-ffi opportunities surfaced by the pancake-goblins dogfood

> **Not a roadmap.** Concrete opportunities surfaced by building a
> real Racket FFI consumer + dialing upstream Spritely Goblins. Each
> entry names what the dogfood hit, what would fix it, and what it
> would cost. Land what makes sense; defer what doesn't; pick a
> graduation criterion for spinning the Racket package out to a
> standalone repo.

> **Posture.** Some findings below are closed by commits on this
> branch; some remain open. Read individual entries for current
> state — the table at § "Issues surfaced via the dogfood + where
> they actually lived" stays current as the live-state surface.
> The rest of this document is **historical record + worked-
> example reference**, especially for the "OCapN 1.0 IS Goblins"
> V1.0 fix (the load-bearing reasoning future agents need to
> understand why pancake's API is shaped the way it is).

## Empirical findings, in the order the dial-spritely demo hit them

These are the rough edges a binding author actually trips on. They're
listed first because each one is concrete evidence — none of this is
speculation; every entry below corresponds to either a failing dial
trace, a fix that landed, or a workaround `racket/dial-spritely.rkt`
had to invent.

### 1. Default CaptpVersion is `PreSpec` but every production OCapN peer is `V1_0`

**Hit it as:**
```text
Abort kind=1 (VersionMismatch) message="captp-version mismatch:
   remote claimed V1_0, local is PreSpec"
```

**Workaround landed:** [`pancake_peer_new_with_version`](../../../crates/ffi/pancake-ffi-runtime/src/handle_lifecycle.rs) + the `PANCAKE_CAPTP_VERSION_*` constants. The dialer explicitly selects V1_0.

**The opportunity:** A first-time binding author will hit this every time. Three options, in order of decreasing aggression:

| Option | Behavior | Cost | Recommendation |
|---|---|---|---|
| **A.** Flip the default. `pancake_peer_new` defaults to V1_0; PreSpec is opt-in. | Breaking ABI change for any host already shipping against the v1 default. Pancake-internal callers wouldn't notice. | Small | Strong default — V1_0 is what real peers speak. |
| **B.** Remove the default. `pancake_peer_new` requires `captp_version`. Drop the no-version variant. | Breaking ABI; forces every binding to confront the choice. | Small + churn | Honest but disruptive. |
| **C.** Keep both; document the new default expectation. | Zero ABI churn. | Zero | Conservative; perpetuates the footgun. |

A. is the right call for pre-1.0 pancake. Bindings update one line.

### 2. `PeerId::from(name)` at the FFI surface is test-fixture-shaped, not spec-canonical

**Hit it as:** `pancake_peer_new("pancake-dialer", "spritely-peer", ...)` passes names that ASCII-pad to 32 bytes ([`PeerId::from_ascii_padded`](../../../crates/core/pancake-foundation/src/id.rs)). The spec-canonical PeerId is `SHA256(SHA256(serialized session pubkey))` per ADR-0015. The names the FFI accepts have no relation to the partner's actual canonical id; pancake overwrites them on handshake.

**Workaround landed:** none — `dial-spritely.rkt` passes cosmetic strings and ignores them.

**The opportunity:**

- Add `pancake_peer_id_from_pubkey(pubkey_32, out_peer_id_32)` — pure helper, derives the canonical id; spares every binding the SHA256 dep.
- Add `pancake_peer_new_from_keypair(keypair, codec, captp_version)` — `my_peer_id` derived from `keypair.public_key()` automatically; no string passed.
- Add `pancake_peer_get_partner_peer_id(peer, out_32)` — readable after the partner's StartSession arrives.

The third is the most consequential — without it, the host has no way to read pancake's authoritative answer to "who is the partner?"

### 3. Stub-keyed `pancake_peer_send_start_session` is a footgun in production

**Hit it as:** the v1 stub-keyed entry is admitted only for in-process pair scenarios. A binding author who uses it against a real OCapN peer gets `InvalidStartSessionSignature` from the partner. The Racket bindings worked around this by making `tcp-bridge.rkt`'s pump call `send_start_session_with_keys` by default + only fall back via `PANCAKE_STUB_KEYS=1` for pancake↔pancake smoke.

**The opportunity:**

| Option | Behavior |
|---|---|
| **A.** Mark stub-keyed `_send_start_session` deprecated; rename to `_send_start_session_for_tests`. | Self-documenting. |
| **B.** Have `_send_start_session_with_keys` accept a NULL keypair (= stub-keyed). One entry, one knob. | More compact ABI. |
| **C.** Leave it as-is; document that it's tests-only. | Status quo. |

B. consolidates the two entries into one; the typed surface stays one-to-one with `pancake_runtime::Peer::send_message(Message::StartSession(…))`.

### 4. No OCapN URI parser at the FFI surface

**Hit it as:** Spritely's seven-caps-peer prints URLs like:
```text
ocapn://JadQ0++RzsD4M+40uLxTWVaVqM10DcBJ.tcp-testing-only?host=127.0.0.1&port=22045
```
For the next test (bootstrap-fetch the echo cap then invoke it), the host needs to construct a sturdyref from that URL. Today the FFI exposes a sturdyref CONSTRUCTOR via the typed `PancakeReference { kind: STURDY }` value type, but the host has to parse the URL itself + extract `(peer-id-bytes, transport, designator, swissnum-bytes)`.

**The opportunity:**

- Add `pancake_ocapn_uri_to_sturdyref(uri_cstr, out_sturdyref)` — parses an OCapN URL into a `PancakeReference { kind: STURDY }`. Reuses pancake's existing URL-parsing code.
- Inverse: `pancake_sturdyref_to_ocapn_uri(sturdyref_ptr, out_buf, out_cap)` — round-trips for diagnostics + binding APIs that surface URLs to users.

This is the single biggest "make typed FFI ergonomic for real consumers" win. Without it, every binding reimplements OCapN URL parsing.

### 5. `PeerLocator` hints are unsupported in the typed StartSession path

**Hit it as:** `pancake_peer_send_start_session_with_keys(peer, kp, transport, designator)` takes `(transport, designator)` only. Locator hints (a routing-optimization key/value multimap; not part of identity per ADR-0012) are deferred.

**Workaround landed:** `dial-spritely.rkt` works because Spritely's `tcp-testing-only` doesn't require hints.

**The opportunity:** Add `pancake_peer_send_start_session_with_keys_and_hints(peer, kp, transport, designator, hint_keys[], hint_vals[], n_hints)`. ADR-0012 § Locators establishes hints aren't part of canonical-signed-bytes, so v1's signing path stays valid; this is a strict additive expansion.

Defer until a consumer hits it.

### 6. Pump-thread wakes on a fixed 1ms sleep, not a wake-fd

**Hit it as:** `bridge/tcp-bridge.rkt` has a `TODO: replace this fixed sleep with a proper wakeup primitive` marker. Today the pump spins on `(sleep 0.001)` between iterations. For a low-throughput dial demo this is fine; for any production binding it's wasted CPU.

**The opportunity:**

- Add `pancake_peer_get_wake_fd(peer, out_fd)` — exposes an eventfd / pipe-fd / WSAEvent the host can `select() / poll() / kqueue` on. Pancake signals the fd when outbound bytes or events become available; the pump parks on `select()` instead of polling.
- WASM consumers don't have fds; the binding pattern is `Promise`-shaped there instead. A condvar-like primitive (`pancake_peer_wait_for_work(peer, deadline_ms)`) covers both worlds.

This is the largest API addition on the list; defer until a real binding actually feels the cost.

### 7. The pancake-side bridge can't actually answer "what's my partner's session pubkey?"

**Hit it as:** `racket/dial-spritely.rkt`'s `SessionEstablished` event surfaces `partner-locator="<unknown>"`. The partner-pubkey (32 bytes) is read into a slot; the partner-locator is a `Debug`-format string of an `Option<PeerLocator>` that was `None` in our test (Spritely's TCP netlayer didn't send back an `acceptable-location`, only its session pubkey).

**The opportunity:**

- The `<unknown>` cosmetic — the FFI emits the literal string `"<unknown>"` when the partner-locator is None. Bindings have no good way to detect that; a `partner_locator_len == 0` sentinel would be cleaner.
- The deeper question: should pancake surface `acceptable-location` per-side as a typed value type rather than a debug string? `partner_pubkey` IS surfaced as 32 raw bytes; `partner_locator` should be `(transport_cstr, designator_cstr, hints_count)` for symmetry — or, simpler, the same OCapN-URI string format from opportunity #4.

Lands naturally alongside opportunity #4 (URI parser + writer).

## Architectural posture findings (not direct FFI improvements)

### A. The Goblins seam is currently zero changes to Goblins

**This is good.** The pancake-goblins dogfood doesn't modify upstream Spritely at all — the dial-spritely test imports `goblins/ocapn/captp` unchanged on Spritely's side, and pancake-via-Racket talks to it through pancake-ffi without touching Goblins's Racket source.

**The lesson:** When the future Goblins-API shim (`captp-pancake/captp.rkt`) eventually lands as a drop-in replacement for `goblins/ocapn/captp`, the seam should stay minimal. Concretely:

- Use **only Goblins's public API**. List every Goblins symbol the shim depends on in a `GOBLINS-SYMBOLS.md` companion doc; treat each one as a stability commitment Goblins makes (or that pancake-goblins audits).
- Avoid `(submod for-captp)` private imports where possible. When unavoidable, the list IS the patch surface — a Goblins maintainer reading this list knows exactly what would break pancake-goblins.
- Use the same Racket-package boundary as Goblins itself. The shim is a separate `raco pkg install`-able Racket package that depends-on `goblins`; not a fork.

### B. The pump-thread model wants a proper concurrency primitive — see opportunity #6 above.

### C. The dial-spritely test is itself a candidate for `reference/tests/`

Today this directory lives in `reference/implementations/`, which is "what's the artifact?" — and the dial-spritely demo IS an artifact (a Racket program). But it's _also_ a test scenario ("does pancake-ffi interop with Spritely Goblins from a Racket consumer?"). 

**Two-axis fit:** when the dial-spritely path stabilizes against a pinned Spritely Goblins submodule commit + the lazy-install is fast enough for CI, it'd move (or grow a sibling) under `reference/tests/pancake-ffi-spritely-interop/` that runs in the CI matrix.

For now it stays as-is — devcontainer-only, manual invocation, no CI gate. The promotion criterion is: pinned Spritely commit + sub-30s end-to-end run.

## MVP resolution post-mortem — what the wire diagnosis surfaced + how it was fixed

This section originally documented a "got partway" MVP that
handshaked but failed at bootstrap-fetch reply. The actual diagnosis
identified two distinct bugs which are now fixed end-to-end. Kept
here for the record + as a worked example of fix-the-protocol-not-the-shim.

### What appeared as one bug was actually two

The original failure was Goblins's `^setup-completer` rejecting
pancake's `op:resolve(0, ...)` response to bootstrap-fetch. Diagnosis:

The error message says Goblins's `^setup-completer` was the routing
target — meaning Goblins's client thinks SETUP is still in progress
when pancake's op:resolve arrives. There's a wire-shape gap somewhere
between pancake's bootstrap-fetch response and what Goblins's
post-handshake setup expects.

**Critical context**: `pancake-conformance-peer` ↔ `goblins-peer`
already passes the OCapN conformance suite — same Goblins client side
(Spritely's stock captp.rkt), Goblins-peer-shaped target instead of
pancake-ffi. So pancake-runtime's bootstrap-fetch wire shape IS in
principle accepted by Goblins. The MVP must be doing something
different from pancake-conformance-peer's path.

### Wire diagnosis (the actual bug)

Wire bytes captured by instrumenting the MVP pump (since dropped
back out, but kept here for the record):

**Goblins client's outbound `op:deliver`** for the bootstrap-fetch:
```text
<op:deliver
  <desc:export 0>                  ; target = bootstrap (pos 0)
  ['fetch <32 bytes swissnum>]     ; args
  0                                ; answer = 0 (V1.0 placeholder; not used)
  <desc:import-object 1>>          ; resolve_me_desc = Goblins's setup-completer
```

**Pancake-ffi's outbound response**:
```text
<op:resolve
  0                                ; answer = 0
  <resolve:fulfill <desc:import-object 1>>>
```

**What V1.0 actually requires** (per `crates/runtime/pancake-runtime/src/v1_0.rs`'s own docstring): "the wire becomes the Goblins-canonical `op:deliver` to the partner's `resolve-me-desc` per ADR-0003." So pancake-ffi should have emitted:

```text
<op:deliver
  <desc:import-object 1>           ; target = the resolve-me-desc Goblins provided
  ['fulfill <desc:import-object 1>]
  (no answer)
  (no resolve_me_desc)>
```

…NOT a raw `op:resolve`. Goblins's `^setup-completer` is installed at bootstrap-pos 0 (per OCapN convention); when pancake's misshapen `op:resolve(0, …)` arrives, Goblins routes it to `^setup-completer` by answer-pos 0, and `^setup-completer` rejects it as `invalid-message` (it only expects the V1.0 resolver-callback shape).

### Where to fix

Two places in `crates/runtime/pancake-runtime/`:

1. **`bootstrap.rs::resolve_for_swissnum`** (the bootstrap-fetch synthesis path) needs to plumb the inbound deliver's `resolve_me_desc` through to the session's resolver-import bookkeeping. Today it builds `Message::Resolve { answer, resolution }` and hands it to the encoder with no awareness of the resolver-callback shape the partner provided.

2. **The V1.0 outbound encoder** (in `v1_0.rs` / `pancake-codec-syrup`) almost certainly already does the resolver-callback translation for the normal deliver-then-resolve path (where `Session::record_recv` records the resolve_me_desc during the inbound deliver). The bootstrap-fetch FAST path bypasses `record_recv` — pancake's dispatch sees the inbound fetch, synthesizes the resolve directly, and never goes through the resolver-import bookkeeping the encoder relies on.

### The actual fix that landed

The root cause turned out to be more conceptually fundamental than the
"plumb the resolve_me_desc through" framing suggested. Per
the principle "**OCapN 1.0 IS Goblins** (there's no OCapN 1.0
implementation that isn't Goblins)", pancake's `CaptpVersion::V1_0`
must imply the Goblins-canonical wire shape. But the type system
made it possible to construct a `Session` with `CaptpVersion::V1_0`
AND empty `ProfileFlags` — a configuration that has no real
counterpart anywhere on the wire (the FLAG is what gates the V1.0
resolver-callback rewrite, NOT the version, in the pre-fix design).

`pancake-ffi`'s `pancake_peer_new_with_version(V1_0)` hit exactly
this trap: it called `Session::new_versioned(_, _, V1_0)` which
constructed a profile with `WireProfile::new(V1_0)` — version V1_0 +
empty flags. The V1_0 outbound translation gate
(`session_needs_v1_0_translation` = `flags.goblins_canonical()`)
returned false; pancake emitted PreSpec-shaped `op:resolve`; Goblins
rejected.

The fix tightens the invariant at the right layer:
`Session::new_versioned(_, _, V1_0)` now uses
`WireProfile::goblins_v1_0()` (V1.0 + GOBLINS_CANONICAL) — because
OCapN 1.0 IS Goblins, anyone constructing V1_0 via the typed
`new_versioned` constructor wants Goblins-canonical. PreSpec stays
empty-flag. The low-level `Session::new_with_profile` + explicit
`WireProfile::new(V1_0)` escape hatch is preserved for property
tests that need the (artificial-but-mechanically-possible)
no-flags-V1_0 configuration.

After this one-line semantic tightening + a Racket FFI cstruct
contract fix (`set-PancakeResolution-kind!` / `set-PancakeArgument-kind!`
auto-generated setters reject malloc'd pointers in Racket 8.16's
contract layer; switching to raw `ptr-set!` sidesteps the contract),
the MVP round-trips end-to-end.

### Lesson worth keeping

**Pancake has nothing canonical of its own.** Pancake speaks OCapN.
Version selectors that imply a wire shape must enforce that shape's
flag-set as a type-level invariant, not as a runtime opt-in. Where
two configurations exist mechanically but only one makes wire-level
sense, the typed constructor must pick the meaningful one + the
no-flag-no-version escape hatch stays at the explicit low-level
constructor for tests.

## Should the GOBLINS_CANONICAL flag separation from CaptpVersion::V1_0 remain?

After researching ADRs 0003 + 0004 + 0008, **yes — the separation is
load-bearing** for these concrete reasons, even though my one-line
typed-constructor fix tightened the common-case mapping:

| Force | Why the separation matters |
|---|---|
| ADR-0003's plugged-codec posture | `Codec::supported_profiles()` returns per-codec wire-shape advertisements. Third-party codecs may legitimately claim `(CaptpVersion::V1_0, ProfileFlags::GOBLINS_CANONICAL)` OR `(V1_0, OTHER_FLAGS)`. The flag bitset is the extensibility hook for codec-specific feature advertisement; collapsing it into the version loses that hook. |
| ADR-0008 / future flag work | Per ADR-0008, the wire-profile bump for split GC (`op:gc-exports` / `op:gc-answers`) is gated on a `FeatureSet::wire_delta` flag that has to be advertised by both peers. The flag layer is where this gating happens. The V1_0 version label is a stable spec-text identifier; the flags are the per-(peer, codec, session) feature ratchet. |
| Cap'n Proto codec's permanent residency at `PreSpec` | Per ADR-0003 § Decision, `pancake-codec-capnp` advertises ONE profile only: `PreSpec`. It can't claim V1_0 because capnp's wire shape isn't the Goblins-canonical Syrup shape. Conflating "V1_0" with "Goblins-canonical" at the type level would make capnp's V1_0-shaped support inexpressible. Even though capnp will never have a V1_0 today, the split anchors that distinction at the type level. |

**What changes: `Session::new_versioned` now picks the
opinionated-common-case profile for `V1_0` (Goblins-canonical),
because every V1_0 implementation in deployment today IS Goblins.**
The low-level escape hatch (`Session::new_with_profile` +
`WireProfile::new(V1_0)`) remains for plugged-codec authors and
property tests. The `v1_0_without_canonical_flag_does_not_trigger_translation`
test in `pancake-runtime/src/v1_0.rs` exercises the escape-hatch
path; it still passes precisely because the escape hatch is preserved.

### What "with detection if possible" looks like long-term

The user asked: "we should have a more clear way to represent it on
the wire with detection if possible." That's already accommodated in
the architecture, per ADR-0004:

- OCapN's `acceptable-location` carries a `hints` hashmap with
  open-keyed entries.
- Pancake reserves the `pancake/` namespace (`pancake/codec`,
  `pancake/feature/*`, `pancake/transport/*`) for hint keys.
- `pancake/codec` is already used: the connector reads the
  listener's advertised codec preference + picks from the
  intersection of supported codecs.

The principled wire-detection path for the GOBLINS_CANONICAL flag is
**a `pancake/feature/goblins-canonical` locator hint**, advertised
in the listener's `acceptable-location`. The connector reads it
during discovery + sets the flag on its session. No need for
implicit "V1.0 always means Goblins" type-level coupling beyond the
typed-constructor's opinionated default.

This is follow-on ADR work; the forcing trigger is "a non-Goblins V1.0
implementation appears in the wild AND a pancake consumer wants to
talk to it without the Goblins-canonical wire shape." That trigger
hasn't fired yet (and may never), so it's correctly deferred.

## 10x architectural view — what the FFI dogfood revealed about pancake's stack

Linus voice, after taking a real step back:

### Pattern observed: deliberate flexibility creating ergonomic footguns

The dogfood revealed a recurring shape: pancake makes the right
architectural choice (extensibility, pluggability, neutrality) at the
type-system layer, but the TYPED CONSTRUCTORS default to the
maximally-flexible-but-least-useful configuration. Every new
consumer hits the same footgun.

| Site | Flexibility (architecturally correct) | Typed constructor default (footgun) |
|---|---|---|
| `WireProfile::new(captp_version)` | Bitset of opt-in flags, per ADR-0003 | Empty flags → no V1.0 wire shape works |
| `pancake_peer_new(my_id, partner_id, codec)` | `partner_id` is needed for the typed Far-ref construction surface | Partner-id is OVERWRITTEN by the handshake; the host-supplied value is unused for production peers (canonical PeerId = SHA256² of session pubkey, derived AT handshake) |
| `pancake_peer_new_with_version(_, _, _, captp_version)` | Per-session CaptpVersion is per ADR-0004 | Default `PANCAKE_CAPTP_VERSION_PRESPEC` — every production OCapN peer (Goblins, conformance suite) is V1.0 |
| Generic `pancake_peer_poll_event_kind` vs typed accessors | Generic accessor for forward-compat with new event kinds | Typed accessors are the right primitive for known kinds; the generic one is almost vestigial. Bindings that mix the two leak events if not careful |
| `Session::record_recv` resolver bookkeeping vs bootstrap-fetch fast path | Fast path is a real perf shortcut for the common `op:fetch <swissnum>` case | The fast path bypasses session bookkeeping that's load-bearing for V1.0 outbound translation. We fixed it by tightening V1.0-default, but the fast path is structurally fragile |

**Architectural recommendation**: a "typed constructors are
opinionated" principle across the pancake stack. Every typed
constructor's default should be the configuration that makes the
common case work; the maximally-flexible config moves to an
explicit low-level constructor that plugged-codec authors /
property-test authors / advanced consumers reach for deliberately.
This is the principle the `Session::new_versioned` fix applied;
the FFI surface should mirror it.

### Pattern observed: fast-path / slow-path divergence carries protocol risk

The bootstrap-fetch synthesis in
`crates/runtime/pancake-runtime/src/bootstrap.rs::resolve_for_swissnum` is
a deliberate fast path — recognize the inbound op:fetch shape,
build the Resolve directly, skip the general inbound dispatcher.
That's correct as performance. But it bypasses session bookkeeping
that the V1.0 outbound encoder relies on. The fix in this commit
(V1.0 → goblins_v1_0 in `Session::new_versioned`) closes the
specific hole, but the structural pattern remains: **anywhere a
fast path bypasses general dispatch, the wire-shape encoder loses
context the general dispatch would have populated**.

Architectural recommendation: audit the other fast paths in
pancake-runtime (handoff route synthesis, sturdyref enliven, GC
batching) for the same pattern. Either the fast path threads the
relevant session bookkeeping itself, or the encoder is restructured
to NOT depend on session bookkeeping at all (the wire shape's
context comes from the inbound message field, not from session
state). The latter is a bigger redesign but more robust.

### Pattern observed: the FFI is the first real multi-language consumer surface, and it's surfacing model-layer issues

Several issues attributed to the FFI in our dogfood iteration
turned out to live at lower layers:

- The V1.0/canonical split footgun → `pancake-session::Session::new_versioned`
- The bootstrap-fetch wire shape bug → `pancake-runtime::bootstrap::resolve_for_swissnum`
- Missing typed List/Set/Tagged variants → `pancake-ffi::value_types` (real FFI gap; ADR-0049 v2 promotion)
- Cstruct contract gripe → Racket FFI binding (real Racket-side bug, not pancake's)

The FFI is doing exactly what dogfooding should: **forcing latent
issues at lower layers to surface where a real consumer would feel
them**. The pancake stack benefits from this: each issue caught
here is one a future non-Rust consumer (Python ctypes, Deno FFI,
Node N-API, Erlang NIF) won't hit.

### Pattern observed: the Racket pump thread is a model bindings will reinvent

Every non-Rust binding will need an equivalent of
`tcp-bridge.rkt`'s pump thread: read bytes from socket → feed to
pancake → step → drain outbound → poll typed events → dispatch.
Five concurrency-careful loops per consumer language.

Architectural recommendation: consider a `pancake-ffi-pump` C ABI
that bundles the pump loop. The host provides:

- A "give me one inbound frame" callback (host's transport read)
- A "take this outbound frame" callback (host's transport write)
- A "deliver this typed event" callback (host's actor system entry)

…and pancake-ffi runs the pump internally, spawning one OS thread
per peer. Bindings turn into thin callback installers.

The downside: bindings lose control of the pump's threading model.
For Racket (which has good thread interop), that's fine. For
single-threaded WASM (no `std::thread`), it's a problem. So the
pump-bundle entry would be a feature-gated opt-in, not the default.

This is a real architectural option, not a small change. Worth
considering before the second non-Rust binding appears (each one
that ships reinvents the pump from scratch, ratcheting up the cost
of switching to the bundled-pump model later).

### Specific bindings-side opportunity: a "pancake-ffi-binding-test-suite"

The wire-interop fixes that landed here (the V1.0 default tighten,
the bootstrap-fetch translation) only got caught because we built
a Racket binding + dialed real Spritely Goblins. The Rust-side unit
tests in pancake-ffi didn't catch them — they exercise pancake↔
pancake only.

Architectural recommendation: a `pancake-ffi-binding-test-suite/` —
a language-agnostic test scenarios catalog ("dial Spritely echo",
"host an echo dialed by Spritely", etc.) that every new FFI
binding runs. Bindings declare conformance by passing the suite.
Probably lives at `reference/tests/pancake-ffi-bindings/` and
parallels `reference/tests/ocapn-conformance/`'s structure.

## Graduation criteria for spinning out a `pancake-goblins` Racket package

The Racket files in [`racket/`](racket/) are usable today as a
pancake-ffi FFI dogfood. The bigger vision — drop-in replacement of
`goblins/ocapn/captp` so the same Goblins app runs on either substrate
— is not built. When the following land, the package is ready to
graduate to its own repo (`github.com/<…>/pancake-goblins`):

1. **`captp-pancake/captp.rkt`** — drop-in replacement for
   `goblins/ocapn/captp`'s `spawn-mycapn` + `captp-session-severed?`
   provides. Backed by pancake-ffi internally.
2. **The seven-caps-peer reference runs unchanged on pancake-goblins.**
   Same `seven-caps-peer.rkt` source, only the `(require
   goblins/ocapn/captp)` line swapped to `(require
   pancake-goblins/captp)`. Passes
   [`reference/tests/ocapn-conformance/`](../../tests/ocapn-conformance/)
   against itself.
3. **`raco pkg install pancake-goblins`** works from a local checkout.
   Proper Racket package manifest + module structure.
4. **`GOBLINS-SYMBOLS.md`** enumerates every Goblins symbol the shim
   depends on, with a note on each (`(submod for-captp)` vs public,
   stability commitment, last verified against `goblins-vX`).

Until then this directory is the seedbed; the graduation question is
"is the surface stable enough to be its own repo?"
