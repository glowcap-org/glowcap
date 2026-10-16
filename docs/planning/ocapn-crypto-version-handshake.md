# OCapN crypto-version transition

Status: active plan. Implementation is waiting on upstream. This is an
internal plan, not text to send upstream. Delete it after the transition is
complete and the code, tests, decision records, and living documentation own
the result.

## Decision

glowcap will not implement OCapN PR 288 while the specification and the
implementations used as outside references describe different opening records.
The current four-field handshake and pinned external checks remain unchanged
while that work settles upstream.

Once the specification, OCapN suite, and Goblins implementations agree on the
new contract, glowcap will make one prerelease cutover to the shared five-field
`op:start-session` record. Standard CapTP 1.0 and `glowcap-next` will both begin
with that record:

```text
<op:start-session "1.0"
                  crypto-version
                  session-pubkey
                  acceptable-location
                  acceptable-location-sig>
```

The opening record does not select `glowcap-next`. The signed locator hints
already carried by the hello continue to offer CapTP behavior, codec, and
features. An updated Goblins peer can complete the standard CapTP 1.0 session.
Two glowcap peers can read the same opening record and settle
`glowcap-next` with their existing offers.

The connection shape is unchanged: no compatibility probe, replacement
connection, baseline retry, or added round trip. The Host recognizes one
opening grammar, because a peer sends its hello before it knows the partner's
profile
([ADR-0103](../decisions/adr/ADR-0103-hello-carried-profile-offers.md)), so
this change cannot land in `glowcap-next` first. Older four-field source
revisions are outside the post-cutover interoperability target.

## Adoption boundary

The [conformance manifest](../ocapn-conformance.md) tracks the current draft
without changing this decision. The deferral covers the hello, public keys,
signatures, identifier derivation, signed envelopes, handoff certificates, and
withdrawal records that depend on the new crypto representation.
An unchanged section can still depend on a changed representation.

Deliver, deliver-only, listen, and projection removal are adopted on next
under [ADR-0251](../decisions/adr/ADR-0251-next-operations-with-retained-crypto.md).
`zig build ocapn-conformance-next` exercises them with the retained opening.
Their adoption does not require this crypto transition.

## Current upstream state

[OCapN PR 288](https://github.com/ocapn/ocapn/pull/288) changes the opening
record from four fields to five. It adds `crypto-version`, replaces the gcrypt
public-key structure with a raw 32-byte key, and replaces the gcrypt signature
structure with a raw 64-byte signature. The `captp-version` value remains
`"1.0"`.

The merged text does not yet state one complete contract. The sender rule says
`Ed25519_SHA256`, while the receiver rule and implementation guide say
`Ed25519`. The public discussion records a preference to name SHA-256 because
the identifiers use it. The normative text must use one token and define the
operations that token selects before glowcap can implement it.

Racket Goblins ([issue 108](https://codeberg.org/spritely/racket-goblins/issues/108))
and Guile Goblins ([issue 988](https://codeberg.org/spritely/goblins/issues/988))
track the same change. [`docs/upstream-watch.md`](../upstream-watch.md) owns
their status. This plan owns what glowcap does after the external contract is
ready.

## What crypto-version means

`crypto-version` declares the cryptographic suite used by the session. Each
side sends one supported value, and a receiver accepts the value defined by the
adopted specification or aborts the handshake. It is not a preference list and
does not negotiate the CapTP profile.

The suite must define these facts together:

- the per-session public-key algorithm and wire representation
- the location and handoff signature algorithm and wire representation
- the public identifier derivation
- the session identifier derivation

The hello and handoff record sections define the value each signature covers
and its canonical encoding. That signing domain stays with the existing
protocol and codec owners, and the algorithm selector does not redefine a
message.

The candidate change uses Ed25519, a raw 32-byte public key, a raw 64-byte
signature, and SHA-256-based public and session identifiers. The adopted
upstream revision decides whether the token is `Ed25519`, `Ed25519_SHA256`, or
another name, and must connect it to the complete set of operations.

In glowcap, the suite is a session fact independent of `CaptpVersion`,
`CodecId`, transport security, and durable peer identity. Session state owns
the accepted suite. Codecs parse and render its wire values. The existing
cryptographic module performs the selected operations. Transports remain
unaware of CapTP cryptography.

One standard suite ships in this transition. The model retains an unknown
inbound token long enough to report a crypto-version mismatch instead of
misclassifying a well-formed hello as malformed. No public algorithm choice
exists, and two suites do not negotiate until OCapN specifies that behavior,
including how handoff certificates identify their suite.

## Contracts that remain in place

- Every peer begins with one standard Syrup hello grammar.
- The hello continues to carry profile offers in its signed locator hints.
- A silent or standard-only Goblins peer settles CapTP 1.0 over Syrup.
- Two glowcap peers may settle `glowcap-next`, Cap'n Proto, and their shared
  features after the hello.
- One Host may hold standard CapTP 1.0 and `glowcap-next` sessions at the same
  time. The selected profile remains a property of each session.
- Session state owns protocol authority. Codecs project values, and transports
  move bytes.
- The portable core remains synchronous and free of I/O.
- A fresh signing key belongs to each session. It does not become durable peer
  identity.
- Signed handoff material remains verifiable across sessions without changing
  the signed value after it was created.

The transition adds no provisional session state, profile discovery round
trip, automatic retry, or old-to-new signed-value translation. One shared
cutover removes the mismatch they would bridge.

## Readiness requirements

Implementation starts only after all of these are observable in public source:

1. The OCapN sender rule, receiver rule, cryptography section, and complete
   implementation-guide example use one crypto token and define the same suite.
2. The OCapN suite parses the five-field record, checks the crypto token and raw
   widths, and includes malformed and signed-handoff coverage.
3. Racket Goblins sends, receives, and verifies the five-field record on its
   default branch or an accepted release branch.
4. The Guile Goblins tracker has reached a compatible implementation or a
   public resolution that identifies no additional wire requirement for this
   transition.
5. The revisions above agree on the raw key and signature forms used by
   `op:start-session`, `desc:sig-envelope`, and `desc:handoff-give`.

An open issue, local glowcap fixture, or glowcap-to-glowcap success does not
satisfy these requirements. Record the exact upstream revisions before moving
the pins.

## 1. Refresh and pin the shared contract

Update the OCapN specification and suite pins together. Update the Racket
Goblins pin to the revision that implements the same five-field record. Record
the Guile Goblins resolution in the upstream watch without claiming live Guile
interop that glowcap does not run.

Read the adopted specification, implementation guide, suite fixtures, and both
Goblins changes before editing the glowcap model. Extract one table containing
the token, field order, key width, signature width, signed bytes, and identifier
derivations. The table is review input only, and the code and fixtures own the
facts once they land.

This step is complete when the exact source revisions are recorded and each
pinned external source describes the same opening record.

## 2. Give the crypto suite one model owner

Add a closed `CryptoSuite` model independent of `CaptpVersion` and `CodecId`.
It should expose the exact token and fixed widths selected by the adopted
standard. Retain an unknown inbound token until session validation so a peer
receives the correct mismatch outcome.

Add the suite to the owned and borrowed `StartSession` models. Make a missing
suite unrepresentable for the new production record. Do not add a nullable
field, a profile-dependent Boolean, or a second copy of the suite rules in a
codec.

This step is complete when every hello constructor and validator receives the
same suite value and no caller can combine the final five-field form with the
old structured key representation.

## 3. Replace the shared opening record

Change the Syrup hello encoder and decoder to the adopted five-field order.
Require the final suite token, the raw 32-byte public key, and the raw 64-byte
signature. Preserve the exact received locator representation used for
signature verification.

Update the Cap'n Proto projection of the neutral model so it cannot lose or
invent the suite, even though the external opening record remains Syrup. Add
separate outcomes for the wrong field count, unknown suite, wrong key width,
wrong signature width, invalid signature, and valid hello under an unsupported
suite.

Remove the four-field form from production parsing and encoding in the same
change. It may remain only as a rejection fixture that proves the cutover does
not silently reinterpret old bytes.

This step is complete when one fixture reproduces the upstream five-field
bytes and changing any field, width, or signed locator byte breaks the focused
check.

## 4. Keep profile negotiation on its current seam

Continue to send `"1.0"` in `captp-version`. Continue to place the local
CapTP, codec, and feature offer in the signed locator hints. After both hellos
arrive, run the existing symmetric settle operation and store its result on the
session.

The standard session and the glowcap session use the same five-field grammar,
with no pre-hello selector. The onion knowledge rule continues to govern when
profile hints may appear in a locator, and does not govern hello syntax.

ADR-0103 remains the profile-negotiation decision. Amend its description of
the shared baseline hello rather than superseding the negotiation design.

This step is complete when a standard-only peer and a glowcap peer both
parse the same opening form, then settle different session profiles from their
offers without another connection or message.

## 5. Apply the suite to signed handoffs

Update the signature in `desc:sig-envelope` and the receiver key in
`desc:handoff-give` to the adopted raw forms. Keep canonical signed bytes under
one codec owner. Verification obtains its key and suite from the live session
that the handoff certificate identifies, following the final upstream rules.

A signed inner record has one post-cutover representation and is never
translated between old and new forms. Unsigned outer framing may still be
projected by the codec carrying the message.

This step is complete when the gifter, receiver, and exporter roles work in all
existing profile combinations, verify the original signatures, and call the
exact exported object.

## 6. Keep Host and product behavior unchanged

Thread the suite through the existing session shell and trace information.
The supported standard fixes it, so bindings gain no caller option. A precise
mismatch or malformed-handshake result surfaces through the existing error
paths.

No probe lifecycle, replacement ownership, retry policy, or transport metadata
is added. Applications never assemble the crypto token or raw handshake fields.
Zig, the C ABI, Rust, TypeScript, Python, and Racket keep choosing `interop` or
`glowcap` with their existing profile vocabulary.

This step is complete when the byte-fed Host, blocking adapter, and completion
loop all open the same five-field handshake and retain independent settled
profiles for concurrent sessions.

## 7. Replace the evidence in one cutover

Add an upstream-derived byte fixture for the complete five-field hello. Its
assertions must name the field count, final token, key width, signature width,
and exact signed locator bytes.

Run the updated OCapN suite against the production Host. Run live Racket
Goblins checks in both directions for the handshake, bootstrap fetch, calls,
promise settlement, and every handoff role. The Goblins peer itself must use
the five-field record. A wrapper that adapts four fields to five is not
interoperability evidence.

Update the mixed-profile Host scenario so both sessions begin with the
five-field hello. One session must settle standard CapTP 1.0 with Goblins. The
other must settle `glowcap-next` between glowcap peers. Both must complete a
bootstrap fetch and a sustained call, and the trace must show that no probe or
replacement session occurred.

Keep these live checks visible individually:

```sh
zig build goblins-interop
zig build goblins-handoff
zig build goblins-gift
zig build goblins-gift-hints
zig build goblins-exporter
zig build goblins-glowcap-pair-gift
zig build ocapn-conformance
```

This step is complete when outside peers and the suite prove the new standard
opening, while the mixed check proves that the existing profile negotiation
still selects each session independently.

## 8. Update decisions and public claims

Amend the handshake decision to make the five-field record and crypto-suite
ownership explicit. Update ADR-0103 only where it describes the common hello.
Keep its signed-hint negotiation decision. Update the handoff decision for raw
key and signature representation.

Update [`docs/shipped.md`](../shipped.md),
[`docs/stability.md`](../stability.md),
[`docs/community-review.md`](../community-review.md), and
[`docs/upstream-watch.md`](../upstream-watch.md) in the implementation change.
Keep the evidence boundaries clear:

- the updated Goblins checks prove live standard CapTP 1.0 interoperability
- the updated OCapN suite proves behavior against its pinned external cases
- glowcap-to-glowcap checks prove `glowcap-next` negotiation and behavior
- no check proves interoperability with an implementation it did not run

Any upstream communication based on this work is written and sent by the
maintainer under [`PROVENANCE.md`](../../PROVENANCE.md).

## 9. Verify and remove the plan

Run focused checks while each owner changes, then close with:

```sh
zig build fmt-check
zig build test
zig build oracle-check
zig build source-check
zig build ocapn-findings-check
zig build ocapn-conformance
zig build check
zig build check-external
```

Run the live Goblins commands from step 7 separately so each result stays
visible. Never weaken a check to accommodate an old external revision.

Delete this file in the final implementation change after all of these facts
are true:

1. every supported session uses the shared five-field opening record
2. the crypto suite has one model owner and one adopted token
3. the updated suite and live Goblins peer pass without an adapter
4. standard CapTP 1.0 and `glowcap-next` still coexist on one Host
5. handoffs preserve their signatures and reach the exact exported object
6. the decisions and public documentation describe the shipped contract
7. all applicable final checks pass.

Remove the plan rather than marking its steps complete.

## Parallel work

The wire changes stay in one lane, so `dev` never speaks half of the new
format to a live Goblins peer.

| Lane | Steps | Owns | Starts |
| --- | --- | --- | --- |
| 1. Wire | 1, 2, 3, 4, 5, then 7 | `src/ocapn/` model, codec and session, the pins and fixtures | When the readiness requirements hold |
| 2. Host and bindings | 6 | `src/driver/`, `src/c_abi/`, `bindings/` | After step 2 |
| 3. Decisions and docs | 8 | ADRs and the pages step 8 names | Drafts after step 3, lands after step 7 |

- Shared files: lane 1 alone edits fixtures and the generated corpus. Lane 2
  regenerates headers and binding mirrors after a sync.
