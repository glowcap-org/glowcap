# Security Policy

pancake implements the CapTP rules for moving authority-bearing references
between peers. A vulnerability in its wire path or session state machine can
affect every product built on top of it, so security reports take precedence
over other work here.

pancake has had no independent security review. It is prerelease software that
has not been hardened or run in production, and the conformance and
interoperability checks measure protocol behavior, which is not the same
thing.

The core bounds inbound frames, nesting, and partner-driven session tables.
A deployment still has to:

- choose the channel it needs: `tcp`, `keyed-tcp`, and `keyed-relay` carry
  cleartext CapTP; iroh, WebRTC, `noise-tcp`, `noise-relay`, and `onion` encrypt
  the session bytes;
- provide sound entropy for identity seeds and protect long-lived secrets;
- set finite handshake and settlement deadlines (`.unbounded` waits forever);
- enforce application authorization, rate limits, and request deadlines.

## Reporting a vulnerability

**Do not open a public issue for a security report.** Contact the maintainer
privately through a GitHub security advisory or the contact details on the
[@jimisaacs](https://github.com/jimisaacs) profile. Include:

- the module, codec, netlayer, or wire shape at risk;
- the invariant you believe is broken;
- a protocol scenario, trace, or written argument that reproduces the problem.

This is a one-person project, so acknowledgement is best-effort within seven
days. Reports of broken protocol invariants take priority.

## What counts as a security issue

Each heading below is an invariant. A report showing any of them broken is a
security issue, not a feature request, even if it needs an unusual configuration
to trigger:

- **Semantics are codec-neutral.** A codec decodes a frame into a reference
  carrying authority the session never exported, or encodes one carrying
  authority it never imported.
- **Codecs do not own authority.** A path lets a codec mint a valid reference
  outside the session's export and import tables.
- **Session state is authoritative.** A path bypasses the export, import,
  answer, or release tables, by reading a codec's internal state or through a
  side channel.
- **A codec must preserve which session row a reference names.** Re-encoding a
  reference under the other codec changes its validated descriptor — its
  variant, table position, kind, or pipeline path — so one table row is read as
  two references, or two rows as one.
- **Inbound frames are attacker-controlled.** A frame escapes the resource caps
  (frame size, table count and retained-byte bounds, nesting depth, validation
  comparison work) to exhaust memory or CPU, or to overflow the stack, instead
  of failing loud with a typed abort.

pancake proves that a target reached directly and through three-party handoff
compares Equal when both paths converge on the same live exporter session. It
does not infer target equality across independently established sessions that
the protocol supplied no authenticated common identity for;
[docs/boundaries.md](docs/boundaries.md) records that edge. If you can show the
remaining edge defeats a revocation, report it.

## Out of scope

A bug in example code that breaks none of the invariants above is an ordinary
issue. Products built on pancake carry their own security policies, and a
dependency issue that does not reach pancake's threat surface belongs
upstream.

## Handoff signature verification

The engine router verifies three-party handoff certificates with
`foundation.crypto` on the production path. Test support exposes
`testOnlyAcceptingVerifier` for in-process substrates and trusted fixtures
only. That stub is never a production default on an untrusted network. A
deployment that swaps it in for live traffic accepts unverified handoff
certificates, so a report about that belongs to the deployment.

## Native relay TLS maintenance

The optional native `wss` carrier compiles a private, minimal Mbed TLS release.
[`tools/deps/fetch-mbedtls.sh`](tools/deps/fetch-mbedtls.sh) is the single
version, release URL, archive-size ceiling, and SHA-256 authority. Updating it
is a security-sensitive dependency change:

1. select an upstream-supported official release and read its security and
   migration notes, including the bundled TF-PSA-Crypto version;
2. update the version and archive digest together, then review the extracted
   directory allowlist, the compiled source inventory in
   `tools/build/mbedtls.zig`, and both minimal configuration headers under
   `src/net/tls/` for newly required or newly reachable code;
3. run `zig build native-tls-build` and `zig build check`, then run the static
   and shared packaging checks on every supported native platform. The native
   TLS gate must retain exact success, hostname, CA, expiry, alert, malformed
   record, truncation, close-notify, and symbol-isolation evidence;
4. update `LICENSE-THIRD-PARTY`, build-step documentation, and the public pin
   description in the same change. Never silently float the release or accept
   an unverified archive.

The committed localhost certificate chain is test-only. The native TLS gate
verifies its authority and fails when the leaf has fewer than 180 days left.
Renew the entire root and leaf together into a new directory with
`tools/check/generate-native-tls-fixture.sh`, inspect the subjects, SAN,
validity, and private-key diff, then replace the three files under
`test/net/fixtures/` in one reviewed commit. Do not preserve the old root key,
reuse these keys outside tests, or weaken the expiry gate to buy time.

## Acknowledgements

Reporters of valid security issues are credited in the corresponding release
notes once a fix lands and disclosure is appropriate, unless they request
otherwise.
