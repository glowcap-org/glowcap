# conformance/accountability-on-pancake

The accountability worked example, moved onto pancake as its CapTP substrate. Same
shape as `accountability-on-goblins` — KERI-anchored identity, a signed Episode
per capability invocation, a Merkle transparency log — but the wire underneath is
pancake's own `engine.Peer`, not Goblins.

Two native pancake peers complete an OCapN handshake over a real loopback TCP
socket. The host publishes an Affordance behind a capability; the caller imports
it and eventual-sends an `invoke`. Every accepted invocation produces a signed,
transparency-logged Episode attributing the **attested** caller. Application
vocabulary (Affordance, Episode, KERI AID, Vat) lives entirely above pancake; the
app imports the `pancake` module and never reaches into the core.

## Running

```sh
zig build accountability
```

One command, no extra runtime: it builds the app against the `pancake` module and
runs both peers on a `std.Io.Threaded` backend (host on a concurrent fiber, caller
on the main one).

## What It Proves

The run walks eight steps and asserts each:

1. Host and caller each **incept** a KERI AID (self-certifying, from an inception
   event).
2. The caller **rotates** its key under pre-rotation discipline.
3. The host **publishes** the Affordance behind an OCapN capability; a session
   opens over TCP.
4. The caller writes an **Attempt** Episode *before* the wire send (intent is
   durable first), then invokes.
5. The host **verifies the caller's signature** over the request and resolves the
   call. Attribution is attested, not a trusted header.
6. A caller the host **cannot attest** (a tampered signature) is **refused** — the
   refusal travels back as a clean broken promise, and the host writes no Episode
   for it. This is the load-bearing accountability property.
7. The host's **Outcome** Episode attributes the *true* caller's AID.
8. Every Episode **audits** (countersignature + payload signature), and the
   transparency roots are stable.

## Files

| File | Role |
| --- | --- |
| `zig/main.zig` | The eight-step driver: two peers, one TCP session, two invocations. |
| `zig/identity.zig` | KERI-shaped identity: incept, rotate, sign, verify (above pancake). |
| `zig/episode.zig` | Episode emission + audit: ephemeral-key signing, KEL countersignature. |
| `zig/log.zig` | Merkle transparency log over Episode hashes. |
| `zig/accountable.zig` | The store that records an Episode and flushes it to disk. |
| `zig/host.zig` | Standalone host for cross-language demos (listens, serves one connection). |
| `zig/three_party_test.zig` | Three-party attribution: C attributes B, not A, after a handoff. |
| `deno/caller.ts` | Deno caller: signs with Ed25519, invokes the Zig host over OCapN/TCP. |
| `deno/demo.ts` | Cross-seam orchestrator: starts the Zig host, runs Deno + Python callers. |
| `python/caller.py` | Python caller: signs with PyNaCl Ed25519, invokes the Zig host. |
| [`why-this-couldnt-be-http.md`](why-this-couldnt-be-http.md) | Why the three-party accountability story needs OCapN, not HTTP. |
| [`FRICTION.md`](FRICTION.md) | Every place pancake was harder to build on than it should be. |

## Generated State

`.data/` holds the durable Episode logs and transparency roots written at run
time. It is generated state (gitignored), never committed.

## Posture

- The integration seam is the documented one: a consumer wraps pancake's runtime
  `Peer` and records Episodes around the send/recv boundary. Here the Affordance
  records its Outcome inside the actor turn; the caller records Attempt/Outcome
  around its own send.
- Not in `zig build check`: it is a worked example homed in `conformance/`, run by
  its own `zig build accountability` step. It needs no runtime beyond Zig.
- Editable worked example: change it when it stops teaching the right boundary.

## Cross-language (Zig host + Deno and Python callers)

The same Affordance that runs natively in Zig is reachable from a Deno caller
over the real C ABI (`libpancake.so`):

```sh
zig build   # builds accountability-host + libpancake.so
deno run --allow-ffi --allow-read --allow-net --allow-run \
  conformance/accountability-on-pancake/deno/demo.ts
```

`zig build demo-accountability` runs the same flow with the host's built path
threaded for you. The hosts bind ephemeral ports by default;
`zig build demo-accountability -Dport=9099` pins the port, rebinding it for
each caller's fresh host. Attach mode is rejected here: a host serves exactly
one caller and exits, so there is no long-lived server to join.

The demo starts a fresh Zig host for each caller, connects from Deno and Python,
generates an Ed25519 identity (Web Crypto / PyNaCl), signs the request, and
invokes. The host verifies the signature and returns `ack:read-thermostat`. A
tampered signature is refused as a broken promise (`UnattestedCaller`). Same
application, three languages, over real OCapN/TCP.

## Three-party introduction (in-memory protocol proof)

```sh
zig build accountability-three-party
```

Proves the central claim: when A introduces B to C via a three-party handoff
(ADR-0009), C's Affordance attributes **B** (the true caller), not A (the
introducer). Uses the `cross_peer` handoff machinery, the accountability
application's KERI attestation, and `actors.Vat` on each peer.
