---
id: ADR-0083
status: accepted
date: 2026-07-15
tags: [captp, session, abort, c-abi]
decision: "Outbound op:abort commits through Peer.commitAbortOutbound with AbortDisposition: encode onto outbound, then close when disposition is .close. App-queued aborts always .close after a successful push; failure projection passes InboundAbort.disposition (handshake refusals stay .keep_negotiating). Encode/push failure on .close still closes without masking the original error. pancake_peer_send_abort is the typed C veneer. CapTP lifecycle stays negotiating | open | closed."
supersedes: []
superseded_by: []
---

# ADR-0083 Outbound abort closes the CapTP session

## Context

Inbound `op:abort` already closed the session in `session.apply`, and
failure projection encoded then closed. An app-queued `Peer.send(.abort)`
recorded and encoded while leaving `session.state == .open`, and
`applySend`'s abort arm was empty despite a comment that claimed teardown. A
partner could take the abort frame while CapTP state still read open, so
further delivers were not refused the way the protocol diagrams require.

This engages session state as authoritative, fail-loud rather than succeed
wrong, and boring C ABI surface: one CapTP commit path, one thin export.

## Decision

`Peer.commitAbortOutbound(abort, disposition)` is the shared commit:

1. Encode and push the abort frame onto `outbound`.
2. If `disposition` is `.close` and the push succeeded, `session_state.close()`.

App-queued aborts call it with `.close` from `emitOutboundMessage` (after
`recordSend`, on `step`). Failure projection (`emitAbortForError`) passes
`InboundAbort.disposition` from `abort_projection`: fatal refusals use
`.close`; handshake refusals (`CaptpVersionMismatch`,
`InvalidStartSessionSignature`, `PartnerKeyMismatch`) use
`.keep_negotiating` with an abort frame for the partner
([ADR-0075](ADR-0075-keyed-tcp-designator.md)).

Close does **not** run at bare `recordSend` time before encode: the partner
must still be able to `takeOutbound` the frame.

When encode or push fails on a `.close` disposition, `emitAbortForError`
swallows that secondary error (so the original dispatch error is not masked)
and still closes: the session is already fatally refused even if the partner
never sees an abort frame.

`pancake_peer_send_abort` queues a typed abort (`AbortKind` wire label +
message); after a successful `pancake_peer_step` the peer is no longer open.
There is no CapTP `draining` state and no second Peer `shutdown` verb,
`AbortKind.graceful_shutdown` is enough. Host transport soft-stop
(`condemned` + flush/close) stays above CapTP.

`zig build meta-check` holds EVENT/send parity: every `PANCAKE_EVENT_*` maps to
a peer send constructor or an allowlist row. `PANCAKE_EVENT_LISTEN` is
allowlisted (engine-synthesized / inbound install); `ABORT` is not.

## Consequences

- Engine and C ABI tests assert outbound carried the abort and
  `session.state == .closed` after step for app/fatal paths.
- Handshake-refusal tests assert `state == .negotiating` with an abort frame
  queued (not merely `!sessionIsOpen()`).
- Further delivers refuse on a closed session.
- Protocol diagram SL-6 ("`op:abort` sent or received becomes Closed") holds for
  open-session teardown; handshake refusals are the named exception.
