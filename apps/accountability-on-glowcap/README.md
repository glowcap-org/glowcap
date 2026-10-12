# Accountability

This application records who made a capability call without asking the host to
trust a caller-supplied name.

The caller signs its request. The host checks that signature against the
caller's current key, follows the caller's key history back to a
self-certifying identifier, and records accepted calls in a signed,
Merkle-rooted log. A forged signature or retired key is refused and leaves no
accepted-call record.

Run the native Zig scenario:

```sh
zig build accountability
```

It needs no additional runtime. The command creates signed records and Merkle
roots under `.data/`, which is generated and gitignored.

## What happens

1. The caller creates an identity from its first signing key, then rotates to
   the next key it had already committed to.
2. The caller records the attempt and sends a signed request, together with the
   key-event history needed to check it.
3. The host derives the claimed identity from that history, validates each key
   change, and requires the request to use the current key.
4. An accepted call produces a signed outcome record called an *Episode*, then
   appends its hash to a Merkle transparency log.
5. The run audits the records, then confirms that a tampered signature and a
   retired key are both refused.

The identity scheme follows a small KERI-shaped model. Its
self-certifying identifier is called an AID. The service being invoked is
called an Affordance. Both concepts belong to this application. glowcap only
carries the capability call and its result.

## Cross-language callers

```sh
zig build demo-accountability
```

This starts a fresh Zig host for a Deno caller and, when
[PyNaCl](https://pynacl.readthedocs.io/) is installed, a Python caller. Each
language builds the same kind of identity and key history. The Zig host
re-derives the caller's AID, accepts a current-key request, and refuses both a
bad signature (`UnattestedCaller`) and a retired key (`UnboundCaller`).

The command needs Deno. Python is optional and is reported as skipped when
PyNaCl is unavailable. `-Dport=9099` pins the port, but attach mode is not
supported: each host serves one caller and exits.

## Attribution after an introduction

```sh
zig build accountability-three-party
```

This scenario runs three glowcap Hosts over loopback TCP. A fetches C's
Affordance and introduces B to it. B's ordinary call redeems the handoff by
opening a direct session to C. When B invokes the introduced capability, C's
record attributes B, the caller, rather than A, the introducer. The proof uses
the same owning Host and application-shaped capability surface as the bindings,
with no test-side handoff routing. Bare TCP is appropriate for an isolated
loopback test. Deployments should choose an authenticated transport.

## Limits

This is an application example, not a complete KERI implementation:

- There are no witness receipts. A controller could withhold a later rotation
  and present an older key history as current.
- The host does not compare histories for the same AID across sessions, so it
  cannot detect two parties being shown conflicting histories.
- Each event has one signing key and one pre-rotation commitment. Events use a
  JSON body rather than KERI's CESR encoding.
- The generated log and root live together under `.data/`. Detecting a rewritten
  log requires an auditor to retain or publish a trusted root elsewhere.

Those limits matter to deployment. They do not change what the example checks:
the host will not record an accepted call unless the presented history binds
the request's signing key to the claimed identity.

See [Design and verification](design.md) for the exact validation walk, refusal
cases, and source map. [HTTP and capability
accountability](http-comparison.md) separates what OCapN supplies from the
identity checks this application adds.
