# Security Policy

pancake implements the CapTP rules for moving authority-bearing references
between peers. A vulnerability in its wire path or session state machine can
affect every product built on top of it, so security reports take precedence
over other work here. This policy applies to every release.

## Security status and responsibilities

pancake has had no independent security review. It is prerelease: not audited,
not hardened, not production-ready. Conformance and interoperability checks
show protocol behavior, not security.

The core bounds inbound frames, nesting, and partner-driven session tables, and
tests exercise those refusals. A deployment still decides four things:

- Choose a netlayer with the channel properties the application needs. Plain
  TCP and keyed TCP are cleartext; iroh supplies encryption.
- Supply sound entropy for identity seeds and protect long-lived secret
  material. The synchronous core does not generate randomness.
- Set finite handshake and settlement deadlines. The library defaults to 0,
  which waits forever; the `pancake` CLI already passes finite ones.
- Apply application authorization, rate limits, and request deadlines above
  pancake.

## Reporting a vulnerability

**Do not open a public issue for a security report.** Contact the maintainer
privately; the contact details are on the
[@jimisaacs](https://codeberg.org/jimisaacs) profile (a GitHub mirror with
private security advisories also exists). Please include:

1. What is at risk: which module / codec / netlayer / wire shape, and the
   invariant it threatens.
2. Reproduction steps. A failing protocol reference scenario is ideal; a written
   trace or argument also works.
3. The pancake property you believe is violated (below).
4. Your assessment of impact and any suggested mitigation.

This is a one-person project ([@jimisaacs](https://codeberg.org/jimisaacs)), so
acknowledgement is best-effort within seven days. Reports of broken protocol
invariants jump the queue.

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
  (frame size, table bounds, nesting depth, validation comparison work) to
  exhaust memory or CPU, or to overflow the stack, instead of failing loud with
  a typed abort.

pancake does not prove that the same target compares equal when it returns
through an arbitrary network path or a three-party handoff;
[docs/boundaries.md](docs/boundaries.md) records that edge. The gap is
unproven, not accepted: if you can show it defeats a revocation, report it.

## Out of scope

- Bugs in _example_ code that don't violate the invariants above (normal
  issues).
- Behavior of products built on pancake (they carry their own security
  policies).
- Dependency issues that don't reach pancake's threat surface (report those
  upstream).

## Handoff signature verification

The engine router verifies three-party handoff certificates with
`foundation.crypto` on the production path. Test support exposes
`testOnlyAcceptingVerifier` for in-process substrates and trusted fixtures
only. That stub is not a production default on an untrusted network; a
deployment that swaps it in for live traffic is misconfigured, not a
protocol feature.

## Acknowledgements

Reporters of valid security issues are credited in the corresponding release
notes once a fix lands and disclosure is appropriate, unless they request
otherwise.
