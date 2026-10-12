---
id: ADR-0143
status: accepted
date: 2026-09-04
tags: [rooms, relay, retry, resilience, resources]
decision: "A raw byte-relay request makes one transport dial. The Rooms directory lifecycle alone retries that request, with jitter inside a bounded automatic window before pausing, while the web relay separately limits live iroh endpoint runtimes and their creation rate."
supersedes: []
superseded_by: []
amends: [ADR-0082, ADR-0086, ADR-0138]
amended_by: []
---

# ADR-0143 Rooms relay retry ownership

## Context

One Rooms browser reconnect passed through two retry owners. The web relay's raw iroh channel spent the shared
discovery budget of twenty-four attempts, then the browser directory lifecycle opened another relay request on its own
backoff. Several tabs or saved directories could therefore keep full discovery campaigns running after the target had
stopped answering. Log suppression combined their terminal reports but did not reduce the work.

The general relay session limit bounded file descriptors. It did not name the private iroh endpoint and Tokio runtime
that every iroh relay channel retains until its session ends, nor how quickly failed channels could create replacements.

## Decision

The relay-specific raw locator entry points in TypeScript, Python, and Racket make one transport attempt. The Rust
reference relay makes the same choice on its raw `connect_owned` call. These paths do not apply discovery continuity,
because the embedding application's request is already the complete attempt whose retry policy ADR-0082 assigns above
CapTP. General connection fronts without an outer owner keep using `DialRetry` and the shared discovery budget.

`DirectoryConnectionLifecycle` owns one reconnect state per held directory. It applies equal jitter to exponential
delays from 500 milliseconds through five seconds. Automatic attempts stop after a sixty-second outage window. The
directory remains held and reads as disconnected. Its card offers an explicit retry, which starts a fresh window. A
connection that survives ten seconds also clears the prior outage and gives a later loss a fresh window.

The Rooms web relay admits iroh work separately from its file-descriptor limit. A raw relay endpoint uses one worker,
and one lease covers it from dial start through byte-pump teardown. The default admits sixteen live iroh endpoints and
a burst of sixteen starts, then restores thirty-two starts per minute. Deployments may set
`GLOWCAP_RELAY_MAX_IROH_SESSIONS` and
`GLOWCAP_RELAY_MAX_IROH_DIALS_PER_MINUTE` explicitly.

## Scope (what this does not decide)

The relay does not cache target health. One caller cannot make a negative reachability claim that suppresses another
caller's dial. Durable session peers remain unattended owners and keep their existing server-side reconciliation policy.
CapTP session state and wire behavior do not change.

## Alternatives Considered

- **Retry inside both the raw channel and Rooms:** rejected because neither owner can bound the complete work.
- **A relay-wide target circuit breaker:** rejected because an untrusted request could suppress another client's valid
  attempt, and changed address hints make a past path failure stale.
- **Only suppress repeated log lines:** rejected because it changes output without reducing endpoint creation.

## Consequences

`DirectoryConnectionLifecycle` owns retry timing, which is not split across live sessions. Relay-specific raw
channels make one attempt across the binding implementations while general connection fronts retain their existing
continuity policy. The Rooms relay retains separate general, registration, and iroh endpoint admission because those
limits pay for different resources.

## Evidence and gate

The directory lifecycle tests cover jitter bounds, the automatic-window transition, explicit retry, and stable reset.
The Rooms web relay test covers live-work admission, creation-rate exhaustion, refill, and idempotent lease release.
The relay-specific binding call sites keep the discovery retry executor out of those paths. The live relay matrix proves
that every binding still carries a browser session after that separation. The repository check remains `zig build check`.
