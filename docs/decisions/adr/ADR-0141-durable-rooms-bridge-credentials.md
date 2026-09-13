---
id: ADR-0141
status: accepted
date: 2026-09-02
tags: [rooms, sessions, persistence, security, bridges]
decision: "A durable Rooms session keeps the credentials a reader answered a bridge form with in a fourth session document of its own, staged before the checkpoint that needs them commits and retained only while that checkpoint names the scope, so a restart replays a bridged identity without the password ever entering the checkpoint, a snapshot, or an export."
supersedes: []
superseded_by: []
amends: [ADR-0134, ADR-0135]
amended_by: []
---

# ADR-0141 Durable Rooms bridge credentials

## Context

A bridge form can ask for a secret: a registered-account password for an
IRC network, say. The session checkpoint records that the reader answered
such a field and never what they typed, because the checkpoint is projected
to attached views, exported, and adopted. The password itself was held in
process memory only, from the command that staged it until the runtime
closed. The tab-hosted session inherited that rule honestly: its documents
live in memory and end with the tab. The standalone session peer inherited
it too, and there it contradicted the peer's whole purpose. The peer exists
to survive restarts. After one, every bridged room replayed its intent,
found no credential, and asked the reader to answer the bridge again, while
the operator's own feed credential on the room server had survived in that
server's operations state all along.

This engages the first principle that a fact has one authority and an
effect stays local to the seam that owns it, and the project value that
effects have a commit point and failures have an owner.

## Decision

`apps/rooms/rust/runtime/src/bridge_secrets.rs` owns credential custody as
`BridgeSecrets`, a fourth session document (`bridge-secrets` in the document
store, `bridge-secrets.json` on the file host) beside the
checkpoint, the effect ledger, and the grant ledger. It is its own document
because it has its own owner: what the reader typed into a secret field,
which no other document may carry. One row per directory and bridge scope,
bounded by `MAX_BRIDGE_SECRET_SCOPES`, holds the answered secrets under the
same 0600 file mode and 0700 directory as the session's identity seed.

The checkpoint stays the one authority on whether a credential is wanted.
A `submitRoomBridgeForm` command stages its secrets into custody before its
checkpoint mutation, so a restart between the two finds the credential and
not a blank. On commit the command settles the staging; on refusal it
discards, which puts back exactly what custody held before. Tokens tell two
in-flight commands for one scope apart, so an older refusal cannot take back
a newer answer. Every realization reconcile first asks custody to retain
only the scopes the checkpoint names with `secretsGiven`. A row a command is
still carrying is exempt, and so is a settled row until a sweep has seen a
checkpoint that names it, because a reconcile queued before the command
committed still carries the older checkpoint. Leaving the last room of a
scope, or submitting a form with no secret, therefore drops the credential;
nothing else does.

The runtime takes custody as a required constructor input. The session peer
opens it from its file documents; the tab-hosted session opens it from the
same in-memory store as its checkpoint, so its credentials live exactly as
long as that tab hosts the session, and the code says so where it does it.

## Scope (what this does not decide)

Custody is plain retention under the state directory's permissions. It is
not an encrypted store, and a reader of that directory can already
reconstitute the session's own authority from the identity seed beside it.
A browser's local workspace still holds no secret across a reload, and a
workspace adopted into a peer carries an intent whose password the peer
never received; both still ask the reader to answer the bridge again, and
the runtime's issue text is that request.

## Alternatives Considered

- **Keep secrets in the checkpoint, redacted on projection**: one document,
  no new custody. Rejected because the checkpoint is exported and adopted
  whole, and a redaction that must never be forgotten is a comment doing a
  boundary's job.
- **Keep memory-only custody and re-ask after every restart**: the shipped
  behavior. Rejected because it makes the durable peer less durable than the
  room server's operations state for the same kind of credential, with no
  security gained: the peer's directory already holds bearer authority.
- **Write custody in the checkpoint mutation's commit callback**: one commit
  point. Rejected because a crash after the checkpoint and before the
  credential write leaves an intent that can never be replayed, while
  staging first leaves at worst an unreferenced row the next reconcile
  sweeps.

## Consequences

The shared Rust runtime maps `SessionDocument::BridgeSecrets` to
`bridge-secrets.json`. `SessionCommands` stages, settles, and discards around
the bridge command's durable mutation. Session reconciliation recovers the
credential revision named by the checkpoint before room realization resumes.
The operating guide and the deploy guide name the document in the state
directory's custody boundary.

## Evidence and gate

The `bridge_secrets::tests` scenarios prove refused replacement, recovery of
staged replacement and removal, corrupt-document refusal, and failed-write
recovery. Native document tests prove exclusive file custody, mode 0600, and
restart. The native session-service room scenario drives password replacement,
refusal, restart, and final pruning through the actual command and realization
path. These run under `zig build rooms-rust-test`, which
`zig build runtime-check` includes.

## Notes

Amends ADR-0134 (the document set a session writes) and ADR-0135 (the
durable session row of the authority graph). ADR-0137 established the
sibling pattern of a document with its own owner outside the checkpoint.
