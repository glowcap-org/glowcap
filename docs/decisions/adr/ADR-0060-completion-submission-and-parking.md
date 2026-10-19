---
id: ADR-0060
status: accepted
date: 2026-10-19
tags: ["driver", "runtime", "performance", "net", "engine", "gc"]
decision: "The runtime stages sends per recipient and submits them before returning a verb to its caller."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0060 Completion submission and parking

## Context

Submitting each receive re-arm or reply separately adds kernel entries. Deferring every submission until a later application call can leave a reply stranded, and a second poller can duplicate the wait already offered by a kernel queue.

## Decision

The runtime stages sends per recipient and submits them before returning a verb to its caller. Blocking receive re-arms wait for the next park. Reaping between verbs does not itself submit work.

When the registered residents support it, the runtime parks inside a resident's own kernel queue and watches the other wake descriptors there. Readiness-only residents retain the descriptor fallback. Watches are armed at the actual park boundary so earlier reaping cannot consume the only wake.

Questioner answer releases wait at the peer's queue tail until the next message can carry them first in one GC frame. An embedding about to park flushes held releases through the Host, so an idle caller does not retain its partner's answers indefinitely.

A caller that explicitly owns a core can request a bounded busy-poll window. It is zero by default, reaps all residents without submitting on every pass, and respects the caller's remaining wait budget.

## Alternatives and consequences

Submitting inside every verb repeats receive and send overhead. Skipping verb-end sends makes latency depend on the application's next call. Persistent multishot watches can produce repeated notifications, and a watch armed too early can lose the park wake.

Busy polling trades CPU occupancy for wake latency and is never an implicit default. Kernel-specific optimizations must retain the common ownership and deadline contract.

## Evidence

Resident, off-turn wake, send batching, release flushing and stepped-runtime tests run under `zig build test`. Existing [benchmark procedures](../../../bench/README.md) attribute the measured syscall costs.
