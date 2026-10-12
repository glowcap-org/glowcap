# Security Policy

glowcap implements the CapTP rules for moving authority-bearing references
between peers. A vulnerability in its wire path or session state machine can
affect every product built on top of it, so security reports take precedence
over other work here.

glowcap has had no independent security review. It is prerelease software that
has not been hardened or run in production, and the conformance and
interoperability checks measure protocol behavior, which is not the same
thing.

The core bounds inbound frames, nesting, and partner-driven session tables.
A deployment still has to:

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
  reference under the other codec must not change its validated descriptor,
  including its variant, table position, kind, or pipeline path. Otherwise one
  table row could be read as two references, or two rows as one.
- **Inbound frames are untrusted.** A frame gets past the resource caps and
  exhausts memory or CPU, or overflows the stack, instead of failing loudly
  with a typed abort. The caps cover frame size, table counts, retained bytes,
  nesting depth, and the comparison work done during validation.

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
only. That stub is never a production default on an untrusted network. A
deployment that swaps it in for live traffic accepts unverified handoff
certificates, so a report about that belongs to the deployment.

## Native relay TLS maintenance

The optional native `wss` carrier compiles a private, minimal Mbed TLS release.
[`tools/deps/fetch-mbedtls.sh`](tools/deps/fetch-mbedtls.sh) is the single
version, release URL, archive-size ceiling, and SHA-256 authority. Updating it
is a security-sensitive dependency change:

1. Select an upstream-supported official release and read its security and
   migration notes, including the bundled TF-PSA-Crypto version.
2. Update the version and archive digest together, then review the extracted
   directory allowlist, the compiled source inventory in
   `tools/build/mbedtls.zig`, and both minimal configuration headers under
   `src/net/tls/` for newly required or newly reachable code.
3. Run `zig build native-tls-build` and `zig build check`, then run the static
   and shared packaging checks on every supported native platform. The native
   TLS check must retain exact success, hostname, CA, expiry, alert, malformed
   record, truncation, close-notify, and symbol-isolation evidence.
4. Update `LICENSE-THIRD-PARTY`, build-step documentation, and the public pin
   description in the same change. Never silently float the release or accept
   an unverified archive.

The committed localhost certificate chain is test-only. The native TLS check
verifies its authority and fails when the leaf has fewer than 180 days left.
Renew the entire root and leaf together into a new directory with
`tools/check/generate-native-tls-fixture.sh`, inspect the subjects, SAN,
validity, and private-key diff, then replace the three files under
`test/net/fixtures/` in one reviewed commit. Do not preserve the old root key,
reuse these keys outside tests, or weaken the expiry check to buy time.

## Acknowledgements

Reporters of valid security issues are credited in the corresponding release
notes once a fix lands and disclosure is appropriate, unless they request
otherwise.
