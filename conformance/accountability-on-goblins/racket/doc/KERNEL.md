# KERNEL.md: what the kernel demonstrates

> The smallest Goblins-side accountability loop: one Vat, one Actor, one
> capability, and one Episode. Multi-Actor and cross-Vat use build on this
> primitive.

If this loop is correct at single-Actor scope, later layers have something
sound to compose. If it is wrong here, every later layer inherits the mistake.

## The eight steps

When `racket conformance/accountability-on-goblins/racket/kernel.rkt` executes,
stdout shows all eight:

```
[1/8] Vat hosts one Actor
      vat instantiated; actor spawned.
[2/8] Actor has KERI-anchored DID (inception event)
      AID: E<44-char-CESR-Blake3-256-SAID>
      KEL: .data/kel/E<...>.kel.jsonl
[3/8] Actor holds OCapN-shaped capability ref to Affordance
      capability: <Goblins near-ref to demo-affordance>
      policy: ((default-grant (actor any) (right access) (affordance demo)))
[4/8] Actor invokes capability (eventual send)
      result: '#hasheq((kind . "demo") (message . "kernel-loop-invoked") (args . ()))
[5/8] Invocation produces Episode (RDF-Star quad)
[6/8] Episode signed by ephemeral key (countersigned by KERI rotation)
      AID rotated; new event SAID: E<44-chars>
[7/8] Episode persisted
      episodes.jsonld: 1 line appended
      transparency.log: 1 leaf added
[8/8] Episode auditable
      verification: OK

Kernel loop closed. Run audit.rkt to print the full trace.
```

## What each step pins

### Step 1: Vat hosts an Actor

A Goblins Vat is instantiated, and an Actor (a capability-disciplined object)
is spawned inside it. Spritely Goblins enforces capability discipline at the
language level, so the example does not simulate the object-capability part in
user code.

### Step 2: Actor has KERI-anchored DID

A KERI Autonomic Identifier (AID) is created with an inception event. The AID is
`E`-prefixed, using CESR Blake3-256 SAID encoding, and is 44 characters long.
The Key Event Log (KEL) is persisted at `.data/kel/<aid>.kel.jsonl`. The
inception event commits to two things:

- the current verkey, a `D`-prefixed Ed25519 transferable verkey
- the digest of the next verkey, so the next key is committed before it is
  exposed. This pre-rotation property is the central KERI piece.

### Step 3: Actor holds capability

In Goblins, the actor reference is the capability. Possession is authorization.
There is no separate permission check, and the only way to invoke the
Affordance is through the reference. The policy is a literal Racket data
structure: `((default-grant (actor any) (right access) (affordance demo)))`.

### Step 4: Capability invocation

The actor receives an eventual-send message. The actor loop processes it. The
Affordance method runs and returns a structured result. The Affordance is a
built-in Goblins method. WASM Components and sandbox tiers are outside this
demonstration.

### Step 5: Invocation produces an Episode

A bitemporal RDF-Star quad is built. The subject is the Actor. The predicate is
`goblins:invoked`. The object is the Affordance plus its result. The named graph
is `goblins:vat/<aid>`, and the bitemporal columns are `valid_time_start` and
`tx_time_start`. The shape is TerminusDB-importable, so a TerminusDB store could
replace the JSON-LD file without changing the Episode shape.

### Step 6: Episode signed by ephemeral key from KERI rotation chain

Four linked actions make up the signature chain:

1. The AID rotates. A `rot` event is added to the KEL, signed by the current
   key, and commits to a new next-key digest. This shows that rotation works and
   pre-rotation discipline holds.
2. A per-Episode ephemeral Ed25519 keypair is generated. In the Sigstore style,
   the ephemeral private key never lives outside this one signing operation.
3. The Episode payload is signed by the ephemeral key.
4. The ephemeral public key is countersigned by the AID's current post-rotation
   verkey, anchoring that ephemeral identity to the KEL.

Every Episode is signed by an ephemeral key anchored to the KERI rotation
chain. The ephemeral key is not derived from the KERI key. The KERI key signs
the ephemeral public key. If the AID is
revoked, past ephemeral signatures verify only for the time window before
revocation. If one ephemeral key is compromised, only one Episode is at risk.
This is the atomic accountability property the kernel demonstrates.

### Step 7: Episode persisted

The Episode JSON is appended as one line to `.data/episodes.jsonld`. Its byte
hash is added as a leaf to the local Sigstore-shaped Merkle transparency log at
`.data/transparency.log`. The log's root is recomputed on every append and
stored at `.data/transparency.root`.

### Step 8: Episode auditable

A separate `audit.rkt` command, driven from outside via
[`../../../episode-audit/run.sh`](../../../episode-audit/run.sh), re-reads the
Episode and verifies the full chain. It checks the ephemeral public key
signature against the AID verkey at that sequence number, then checks the
Episode signature against the ephemeral public key. The verification
round-trips, so auditability is part of the structure.

## What the kernel does not cover

The kernel covers the atomic loop. Anything that appears only after several
loops compose is out of scope:

| Concern                                               | Why deferred                                                                                                                                                                            |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Multiple Actors, capabilities, and Episodes           | The kernel is single-Actor. Multi-Actor coordination is separate work.                                                                                      |
| Network code, including Iroh and cross-Vat federation | Cross-Vat federation is post-kernel work.                                                                                                                                               |
| TerminusDB store                                      | The Episode shape is TerminusDB-portable, so a real store can replace the JSON-LD file later.                                                                |
| WASM Component Model                                  | The kernel uses a built-in Goblins method as the Affordance. WASM-hosted Affordances are post-kernel.                                                                                   |
| Sandbox tiers                                         | A tier system belongs to the Affordance runtime. The built-in method already runs under Goblins's capability discipline, which is the security foundation a tier system would build on. |
| Policy governance UI                                  | The kernel's policy is a literal Racket data structure in `kernel.rkt`. Rich authoring belongs with a more developed authority surface.                                                 |
| Real Sigstore service integration                     | The kernel uses the Sigstore shape (a transparency log plus ephemeral signing). Upstream integration is deferred.                                                                 |

## What the kernel shows about the substrate

- **The accountability loop works at the smallest scale.** Each primitive in
  the loop is implemented, not stubbed: Invocation, Decision, Effect, and
  Episode. Goblins enforces capability discipline at the language level.
  Episodes are signed and queryable.
- **The capability shape holds end to end.** Goblins forces capability-shaped
  code, and no out-of-band path bypasses authority. Episode emission, signing,
  and transparency-log registration stay inside the Vat process, so the
  cryptographic chain is local and auditable.
- **The bitemporal, signed shape composes.** The Episode shape is meant to
  carry over to multi-Actor and cross-Vat use unchanged.
- **Conformance is checked at a named boundary.** The Python verifier checks
  SAIDs, signatures, and pre-rotation discipline against the KEL. Witness
  receipts and full keripy `Serder` ingestion are not covered. Within that
  boundary, "KERI in Racket" is checked, and the same harness is the
  regression check for these primitives in any other language implementation.

## See also

- [`../../README.md`](../../README.md): build/run and file map
- [Spritely Goblins](https://spritely.institute/goblins/): the upstream OCapN
  reference implementation this Vat builds on
