# KERNEL.md — what the kernel demonstrates

> The smallest demonstrable Goblins-side accountability loop: one Vat, one Actor, one capability, one Episode. Single-Vat single-Actor scope throughout — the loop primitive that multi-Actor and cross-Vat usage compose over.

The kernel is the smallest demonstrable case of the loop the Vat then extends to multi-Actor coordination and cross-Vat federation. Get this loop honest at single-Actor scope and every later layer composes naturally; get it wrong and every later layer inherits the wrong shape.

## The eight steps

When `bash reference/implementations/accountability-on-goblins/stack/run.sh kernel` executes, you see all eight on stdout:

```
[1/8] Vat hosts one Actor
      vat instantiated; actor spawned.
[2/8] Actor has KERI-anchored DID (inception event)
      AID: E<44-char-CESR-Blake3-256-SAID>
      KEL: /work/accountability-on-goblins/racket/.data/kel/E<...>.kel.jsonl
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

### Step 1 — Vat hosts an Actor
A Goblins Vat is instantiated. An Actor (capability-disciplined object) is spawned inside it. The actor-loop is real; capability discipline is enforced at the language level by Spritely Goblins. This is the runtime layer of the substrate — the L1 of the foundational stack.

### Step 2 — Actor has KERI-anchored DID
A KERI Autonomic Identifier (AID) is created via inception event. The AID is `E`-prefixed (CESR Blake3-256 SAID encoding, 44 chars). The Key Event Log (KEL) is persisted at `.data/kel/<aid>.kel.jsonl`. The inception event commits to:
- Current verkey (`D`-prefix Ed25519 transferable verkey)
- Pre-rotation: digest of the next verkey, committing to it before exposing it (the load-bearing KERI property)

### Step 3 — Actor holds capability
In Goblins, the actor reference IS the capability. Possession IS authorization. There's no separate "permission check"; the only way to invoke the Affordance is through the reference. The Policy is a literal Racket data structure declaring `((default-grant (actor any) (right access) (affordance demo)))` — the smallest workable form.

### Step 4 — Capability invocation
The actor receives an eventual-send message. The actor-loop processes it. The Affordance method runs and returns a structured result. **The Affordance is a built-in Goblins method**; WASM Components and a sandbox tier system would land later if the Vat grew that direction.

### Step 5 — Invocation produces an Episode
A bitemporal RDF-Star quad is built: subject (Actor), predicate (`goblins:invoked`), object (Affordance + result), named graph (`goblins:vat/<aid>`), bitemporal columns (`valid_time_start`/`tx_time_start`). The shape is TerminusDB-importable — a future TerminusDB integration would swap the JSON-LD file for a TerminusDB store without changing the shape.

### Step 6 — Episode signed by ephemeral key from KERI rotation chain
**This is the load-bearing step.** Three signatures compose:
1. The AID rotates — `rot` event added to KEL, signed by the current key, committing to a new next-key digest. This proves rotation works and pre-rotation discipline holds.
2. A per-Episode ephemeral Ed25519 keypair is generated. Sigstore-style, the ephemeral private key never lives outside this single signing operation.
3. The Episode payload is signed by the ephemeral key.
4. The ephemeral pubkey is countersigned by the AID's CURRENT (post-rotation) verkey, anchoring the ephemeral identity to the KEL.

The result: every Episode is signed by an ephemeral key derived (in the Sigstore sense — anchored, not key-derived) from the KERI rotation chain. Revoke the AID → all past ephemeral signatures verify only for the time window before revocation. Compromise an ephemeral → only one Episode is at risk. **This is what "AI agents earn autonomy you can verify" looks like at the atomic level.**

### Step 7 — Episode persisted
The Episode JSON is appended as one line to `.data/episodes.jsonld`. Its byte hash is added as a leaf to the local Sigstore-shaped Merkle transparency log at `.data/transparency.log`. The log's root is recomputed on every append and stored at `.data/transparency.root`.

### Step 8 — Episode auditable
A separate `audit.rkt` command (driven from outside via [`reference/tests/episode-audit/run.sh`](../../../../tests/episode-audit/run.sh)) re-reads the Episode and verifies the full chain: ephemeral pubkey signature against AID@seq verkey, Episode signature against ephemeral pubkey. The verification round-trips. **Auditability is structural, not bolted on.**

## What the kernel deliberately does NOT cover

The kernel proves the atomic loop. Anything that emerges only through composition is out of scope:

| Concern | Why deferred |
|---|---|
| Multiple Actors / capabilities / Episodes | Single-Actor scope is the kernel's deliberate boundary. Multi-Actor coordination would land later. |
| Network code (Iroh, cross-Vat) | Cross-Vat federation is post-kernel work. |
| TerminusDB store | The kernel preserves the TerminusDB-portable Episode shape; a real store integration would land later. |
| WASM Component Model | The kernel uses a built-in Goblins method as the Affordance. WASM-hosted Affordances are post-kernel. |
| Sandbox tiers | Affordance-runtime concept; the kernel's built-in method already runs under Goblins's capability discipline (the security foundation a tier system would build on). |
| Policy governance UI | The kernel's Policy is a literal Racket data structure in `kernel.rkt`. Rich authoring would land with a more developed authority surface. |
| Real Sigstore service integration | The kernel uses the Sigstore *shape* (transparency log + ephemeral signing); upstream integration is deferred. |

## What the kernel proves about the substrate

- **The accountability loop is honest at the smallest demonstrable scope.** Each primitive in the loop (Invocation, Decision, Effect, Episode) is real, not stubbed. Capability discipline is enforced by Goblins at the language level. KERI primitives are spec-conformant (verified by the keripy oracle). Episodes are signed and queryable.
- **The capability shape is preserved end-to-end.** Goblins forces capability-shaped code at the language level — there is no out-of-band path that bypasses authority. Episode emission, signing, and transparency-log registration stay inside the Vat process, so the cryptographic chain is local and auditable.
- **The bitemporal-and-signed shape composes.** The Episode emitted here is the same shape that scales to multi-Actor coordination, federated governance, and audit-bearing cross-Vat workflows. The same primitive holds at every scope it composes through.
- **Conformance is provable.** The keripy oracle verifies the Vat's KERI outputs are real KERI. Without conformance, "KERI in Racket" would be a claim. With it, it's a fact — and the same harness becomes the regression gate for any future implementation of these primitives in another language.

## See also

- [`../../README.md`](../../README.md) — Vat layout, build/run, file map
- [Spritely Goblins](https://spritely.institute/goblins/) — the upstream OCapN reference implementation this Vat builds on
