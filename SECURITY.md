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

- choose the channel it needs: TCP and keyed TCP are cleartext; iroh and
  WebRTC are encrypted;
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
  (frame size, table bounds, nesting depth, validation comparison work) to
  exhaust memory or CPU, or to overflow the stack, instead of failing loud with
  a typed abort.

pancake does not prove that the same target compares equal when it returns
through an arbitrary network path or a three-party handoff;
[docs/boundaries.md](docs/boundaries.md) records that edge. The project has not
accepted that gap, so if you can show it defeats a revocation, report it.

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

## Acknowledgements

Reporters of valid security issues are credited in the corresponding release
notes once a fix lands and disclosure is appropriate, unless they request
otherwise.
