# Security Policy

glowcap implements the CapTP rules for moving authority-bearing references
between peers. A vulnerability in its wire path or session state machine can
affect every product built on top of it, so security reports take precedence
over other work here.

glowcap has had no independent security review. It is 0.1.0 alpha software that
has not been hardened or run in production. The conformance and
interoperability checks test protocol behavior and say nothing about
hardening.

The core bounds inbound frames, nesting, and partner-driven session tables.
The [threat model](docs/threat-model.md) names each untrusted input with the
parser, bound, search, and proof behind it. A deployment still has to:

- Choose the channel it needs: `tcp`, `keyed-tcp`, and `keyed-relay` carry
  cleartext CapTP. iroh, WebRTC, `noise-tcp`, `noise-relay`, and `onion` encrypt
  the session bytes.
- Provide sound entropy for identity seeds and protect long-lived secrets.
- Set finite handshake and settlement deadlines (`.unbounded` waits forever).
- Enforce application authorization, rate limits, and request deadlines.

## Reporting a vulnerability

**Do not open a public issue for a security report.** Contact the maintainer
privately through a GitHub security advisory or email
[security@glowcap.org](mailto:security@glowcap.org). Include:

- The module, codec, netlayer, or wire shape at risk.
- The invariant you believe is broken.
- A protocol scenario, trace, or written argument that reproduces the problem.

Glowcap LLC aims to acknowledge reports within seven days. Reports of broken protocol invariants take priority.

## Supported versions

Fixes land on `main` and in the next tagged release. Only the latest release
receives fixes, so a deployment tracks it.

## Disclosure

A report stays private until a fix is published or ninety days have passed
since acknowledgement, whichever comes first. The reporter and the maintainer
can agree on a different date when a fix needs longer or when the issue is
already public.

## What counts as a security issue

A session keeps tables of the references it has exported and imported and the
answers it owes, and a codec turns frames into positions in those tables. A
report showing any of these rules broken is a security issue, even if it needs
an unusual configuration to trigger:

| Rule | What breaking it looks like |
| --- | --- |
| Codecs carry no authority of their own. | A codec decodes a frame into a reference carrying authority the session never exported, or encodes one carrying authority it never imported. |
| Only the session tables make references. | A path lets a codec mint a valid reference outside the session's export and import tables. |
| Session state decides. | A path bypasses the export, import, answer, or release tables, by reading a codec's internal state or through a side channel. |
| A reference names the same row under either codec. | Re-encoding a reference under the other codec changes its validated descriptor (its variant, table position, kind, or pipeline path), so one table row reads as two references, or two rows as one. |
| Inbound frames are untrusted. | A frame gets past the caps on frame size, table counts, retained bytes, nesting depth, or validation work, and exhausts memory or CPU or overflows the stack instead of failing with a typed abort. |

If a target is reached both directly and through a three-party handoff, glowcap
proves the two references compare equal when both paths lead to the same live
exporter session. It does not assume two targets are equal when they come from
separate sessions that share no authenticated identity.
[docs/boundaries.md](docs/boundaries.md) records that limit. If you can show
that this limit lets someone defeat a revocation, please report it.

## Out of scope

A bug in example code that breaks none of the invariants above is an ordinary
issue. Products built on glowcap carry their own security policies, and a
dependency issue that does not reach glowcap's protocol surface belongs
upstream.

## Handoff signature verification

The engine router verifies three-party handoff certificates with
`foundation.crypto` on the production path. Test support exposes
`testOnlyAcceptingVerifier` for in-process substrates and trusted fixtures
only. The engine's own router never takes it. An embedder that routes
handoffs itself through the `SignatureVerifier` hook and installs the stub
accepts unverified certificates, so a report about that belongs to the
embedder.

## Relay TLS dependency

The optional `wss` carrier compiles a private, minimal Mbed TLS release, pinned
by version, release URL, archive-size ceiling, and SHA-256 in
[`tools/deps/fetch-mbedtls.sh`](tools/deps/fetch-mbedtls.sh). Updating the pin
is a security-sensitive dependency change, and
[Maintaining glowcap](docs/maintaining.md#relay-tls-maintenance) has the
procedure.

## Acknowledgements

Reporters of valid security issues are credited in the advisory or commit that
lands the fix, once disclosure is appropriate, unless they request otherwise.
