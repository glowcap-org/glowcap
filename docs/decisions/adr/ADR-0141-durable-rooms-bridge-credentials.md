---
id: ADR-0141
status: accepted
date: 2026-09-02
tags: [rooms, sessions, persistence, security, bridges]
decision: "Rooms retains bridge credentials in private scoped custody, stages them before dependent workspace intent commits, and recovers exact credential witnesses across restart without disclosing secrets in views or exports."
supersedes: []
superseded_by: []
amends: [ADR-0134, ADR-0135]
amended_by: []
---

# ADR-0141 Durable Rooms bridge credentials

## Context

Bridge forms may request credentials that must survive session restart. Their
values have a different disclosure boundary from shared workspace intent,
snapshots and portable exports.

## Decision

`session::bridge_secrets::BridgeSecrets` owns a bounded private credential
document. Credential rows are scoped to the actual directory and bridge.
Process storage enforces private file and directory modes. Browser storage
retains credentials under its session storage owner. A snapshot or export
contains intent and recovery witnesses, never a secret value.

Managed bridge dispatch retains the exact origin and source. Credential
acquisition stages secret custody before committing dependent intent. Refusal
recovers the preceding custody. Tokens and witnesses fence an older response
against a newer answer. The retention owner prunes only unreferenced scopes
while preserving admitted staging and recovery.

Credential storage, workspace acquisition and upstream dispatch have separate
commit points. Canceling observation cannot erase an admitted credential write.
Unknown outcomes retain their original evidence. On restart, realization selects
only the witness committed with its original intent, and requests a new answer
when that custody is unavailable.

The [session guide](../../rooms/session.md#discovery-signaling-archives-and-bridge-secrets)
owns production composition. Secret retention relies on the storage owner's
permissions and origin boundary. It provides no additional encrypted vault.

## Evidence

The [credential contracts](../../../apps/rooms/rust/runtime/src/session/bridge_secrets/tests.rs)
check staged replacement/removal, refused writes and recovery.
The [runtime executor](../../../apps/rooms/rust/proofs/src/session_executor.rs)
exercises managed bridge acquisition and exact-source effect recovery on the
process and browser storage paths.
