---
id: ADR-0209
status: accepted
date: 2026-10-12
tags: [rooms, admission, deployment]
decision: "Rooms owns bounded process-local work admission at effect boundaries, configured through service startup and deployment."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0209 Rooms process-local work admission

## Context

Payload and concurrency ceilings bound retained work but do not stop repeated
small requests, reconnects or expensive failed starts. A directory also cannot
protect direct payloads after it introduces two peers. Shared collaboration
needs accounting that cannot reset by reconnecting or delegating a child grant.

## Decision

Rooms owns synchronous token buckets above CapTP. Native subjects come from
proved transport identity, shared subjects from already validated Loam grant
lineage, and incoming direct subjects from the receiving channel. Unproved HTTP
work has a deployment envelope and an optional socket-address policy. A
caller-provided identity never chooses its subject.

One bounded registry preflights every dimension before committing any debit.
Depleted rows survive disconnect and table pressure. Fully restored rows may
retire through bounded maintenance. Existing-key checks allocate nothing.
Rates remain fixed throughout an owner's lifetime and operators configure
them through existing arguments, environment and Compose overrides.

Refusal occurs before dispatch and creates no server retry queue. Already
admitted effects retain the existing committed, unsent or uncertain outcome.
Receipt lookup cannot re-execute a mutation. Cleanup has independent allowance
and custody, preserving its original authority checks.

Loam provides borrowed forwarding work and validated ancestry to embeddings.
It contains no Rooms policy or clock. Registrations that do not request the
forward admission hook incur no work-metadata walk.

## Consequences

Restart resets short-lived debt and replicas enforce independent budgets.
This avoids a database transaction on every message. Fleet-wide quotas and
persistent abuse debt need a separate owner and measured requirement.

Authenticated rotating-key abuse remains possible. Recipient, aggregate,
queue and byte bounds limit its local impact but do not establish a hosting
security guarantee. Per-address policy is explicit because shared proxies
and networks can group healthy users.

The [admission guide](../../rooms/admission.md) owns configuration, dispatch
attribution and recovery behavior. Typed tests and allocation measurements
hold the mechanism independently of network timing.
