# Security Policy

pancake's **entire purpose** is to move authority-bearing references between
peers without compromising the unforgeability semantics CapTP names. A
vulnerability in pancake's wire path or session state machine is a vulnerability
in every product built on top of it, so security reports take precedence over
all other work here. This policy applies to every release.

## Reporting a vulnerability

**Do not open a public issue for a security report.** Contact the maintainer
privately; the contact details are on the
[@jimisaacs](https://codeberg.org/jimisaacs) profile (a GitHub mirror with
private security advisories also exists). Please include:

1. What is at risk: which module / codec / netlayer / wire shape, and the
   invariant it threatens.
2. Reproduction steps. A failing protocol/oracle scenario is ideal; a written
   trace or argument also works.
3. The pancake property you believe is violated (below).
4. Your assessment of impact and any suggested mitigation.

This is a one-person project ([@jimisaacs](https://codeberg.org/jimisaacs)), so
acknowledgement is best-effort within seven days. Reports of broken protocol
invariants jump the queue.

## What counts as a security issue

A report that shows a violation of any of these is a security issue, not a
feature request, even if it needs an unusual configuration to trigger:

- **Semantics are codec-neutral.** A codec that decodes a frame into a reference
  carrying authority the session did not export, or encodes a reference carrying
  authority the session did not import, is a security issue.
- **Codecs do not own authority.** A path that lets a codec mint a valid
  reference outside the session's export / import tables is a security issue.
- **Session state is authoritative.** A path that bypasses the export / import /
  answer / release tables (reading a codec's internal state, or via a side
  channel) is a security issue.
- **Reference identity is codec-neutral.** A reference value that does not
  compare equal to the same target's encoding under the other codec is a
  security issue: it leaks authority laundering, letting an adversary re-encode
  a reference to escape revocation.
- **Inbound frames are attacker-controlled.** A frame that escapes the resource
  caps (frame size, table bounds, nesting depth) to exhaust memory or overflow
  the stack, rather than failing loud with a typed abort, is a security issue.

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
