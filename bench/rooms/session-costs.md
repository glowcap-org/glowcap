# Rooms session cost measurements

Measured against baseline commit `5bab7d945` on 2026-10-09, using the pinned
development container. These are allocation and traversal counts, not a claim
about network latency or user-visible response time.

## Host route ownership

`zig build bench-host-locator` measures 1,024 warmed operations per case.
Setup and catalog growth are outside the window. The configured profile is
CapTP next with Cap'n Proto and default features; four carried route hints
exercise heap-backed hello scratch. Both select and retain produce these counts:

| Operation | Allocations before → after | Requested bytes before → after |
| --- | ---: | ---: |
| Replace, no carried hints | 18 → 9 | 490 → 245 |
| Replace, four carried hints | 35 → 18 | 1,176 → 728 |
| Repeated accept fallback | 9 → 0 | 245 → 0 |

The Node owns the sole durable locator snapshot. Host completion borrows input
and caller-owned hint scratch until that snapshot is retained. The public owned
preparation API still returns independent storage. Driver budgets cover both
replacement verbs, scratch overflow, aliased inputs, every allocation refusal
and owned preparation after Host teardown.

## Membership reconciliation

The production membership scenario counts actual `snapshot` invocations through
the session content endpoint. An unchanged-standing draft gesture requires
three requests before and two afterward: one for the gesture, one for the worker,
and no separate standing read. The standing worker consumes the wake snapshot.
Conflict and settlement require fresh reads; uncertain commands retain their
original ownership. Inheritance, empty overrides, source pause/resume and unrelated
changes run through that same scenario.

## Browser projection

`zig build bench-rooms-projection` counts visits through the production UI
projection. Each conversation displays 64 lines and retains custody of 32.
The benchmark also checks exact held and unheld display state.

| Conversations | Conversation visits before → after | Line ID reads before → after |
| ---: | ---: | ---: |
| 16 | 288 → 16 | 24,832 → 512 |
| 64 | 4,224 → 64 | 99,328 → 2,048 |
| 256 | 66,048 → 256 | 397,312 → 8,192 |

One temporary map borrows presented conversations through the projection pass;
one scalar set indexes each conversation's held line IDs. Archive-share state
uses a temporary lookup at the same seam. These indexes copy no messages or
capabilities and retain no workspace snapshot between passes. The cost regression
fails against the baseline's repeated searches.

`RoomsManagedActivityReader::read` classifies incoming custody from the JavaScript
event it already decoded. This removes a second full Rust JSON tree per incoming
event. Production browser journeys exercise both line routes and other authority
handles. Outgoing reference collection now returns its final vector directly;
Rust already adopted the previous intermediate vector's allocation, so this is
a simpler ownership expression without an allocation-saving claim.

## Reproduce

Run commands through `.agents/skills/work/bin/glowcap-dev`:

```sh
zig build bench-host-locator bench-rooms-projection
zig build test -Dtest-filter='core host locator'
zig build rooms-rust-test rooms-server-test rooms-managed-rooms-browser-test
```

The [memory ledger](../../.agents/skills/memory-ledger/SKILL.md) inventories the
remaining owners. Cost budgets establish the measured shape; protocol and browser
scenarios establish behavior.
