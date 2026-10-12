# Rooms contract fixtures

These JSON documents pin the portable Rooms application contract: what a
reader accepts, what it refuses, and what it produces, for every surface the
Rust application shares between the native binaries and the browser. The
`rooms-contract-proofs` crate replays each one natively under `zig build
rooms-rust-test` and in Wasm under `zig build rooms-rust-browser-test`, so a
change that moves a boundary is exposed when the two target-specific steps run.

A fixture is static test material. Its capability values, swiss numbers, and
entropy confer no authority anywhere, and two notations in them are fixture
conventions rather than Rooms encodings: `{ "integer": "7" }` keeps an
integer's wire type distinct from a float, and `{ "capability": true }` stands
where a live reference would sit. Text that must survive as isolated UTF-16
surrogates is stored as an encoded string, so no JSON reader can quietly
replace it with a scalar value.

## What each fixture holds

The proof module named beside each file is under `src/`.

| Fixture | Proof | What it pins |
| --- | --- | --- |
| `failures.json` | `failures` | The protocol failure codes and how a bare, wrapped, unknown, or nested reason is read back. Only the leading canonical code is authoritative. Code-shaped detail cannot impersonate one. |
| `session-documents.json` | `documents` | The document ceilings and how ordinary UTF-8, byte-order marks, and malformed bytes decode. |
| `grants-v1.json`, `grants-suspended-v1.json`, `grants-surrogate-v1.json` | `grants`, `grant_protocol`, `documents` | Version-one grant documents: an interact grant with a padded label and no history access, its suspension with a note beside a revoked tombstone, and a label that is one isolated high surrogate, which a rewrite must preserve. The derivation vector uses sixteen bytes of `0x5a` as root entropy. |
| `grant-commands.json` | `grant_protocol` | Grant commands for every access level: issue, retry, conflict, policy patches, note clearing, and revocation. |
| `checkpoints.json` | `checkpoint`, `room_links` | The checkpoint parser and redactor: missing fields, nullable and optional normalization, relationships, route authorities, WebSocket URLs, and surrogate text. Bridge answers keep their insertion order because the retry ledger hashes checkpoint JSON. The redactor removes room bearer links independently of bridge intent. |
| `session-state.json` | `session_state` | Durable checkpoint and effect documents, and one action trace of the shared state contract with its exact writes, retry and refusal outcomes, and revisions. An oversized embedded checkpoint exercises the envelope's byte ceiling apart from the standalone wire limit. |
| `session-commands.json` | `session_commands`, `command_admission` | The pure session commands and their join and peering helpers: acceptance, the exact resulting checkpoint, impact, and retry material, across several directories and rooms, cascading retirement, invitations, rejoining, stale authority generations, bridge scope, and UTF-16 input. Secrets never enter retry material. |
| `session-command-admission.json` | `command_admission` | The command dispatcher's access and envelope checks up to a stubbed mutation: argument count, UTF-16, encoded-byte, and revision limits, and a handed invitation received then accepted through both checkpoint reducers. |
| `session-results.json` | `session_results` | Result-command preparation, application, and resume, driven through the durable state engine both uninterrupted and restarted at every write. |
| `reconciliation.json` | `reconciliation` | State-sync cases followed by the equality check durable reconciliation uses: stale routes and tokens, room retirement isolation, acquired-authority conflicts, publication versions, reconnect results, direct registration, and collection limits. Every changed fact is replayed to prove idempotence. |
| `session-events.json` | `session_events` | Event-reader decisions: header and integer bounds, mutation identity, archive coordinates, presence and room facts, escaped tags, surrogates, nulls, and positional arrays. A valid attachment guard outlives delivery. A malformed one leaves no guard behind. |
| `snapshots.json` | `snapshot` | Snapshot-reader cases for all four facet projections and the overflow degradation order. Large overflow inputs are rebuilt from bounded rows by the proof. Only their answers are stored. |
| `operator-views.json` | `operator_views` | Operator page rows for every category, member bounds, stewardship relations, decimal revisions, listener relationships, and bridge gateway records. Nested objects refuse positional arrays. |
| `workspaces.json` | `workspace` | Saved workspace documents decoded, normalized, and exported against a fixture route authority. |
| `conversation.json` | `conversation` | Room history under its line and byte bounds, file transfer state through chunked upload progress, and the authority a file post needs. |
| `membership.json` | `membership` | Membership answers, and the inbox's messages, notices, presence, and queue behavior. |
| `room-protocol.json` | `room` | Every room mode combination, public offers, the line and file limits, and line edit and withdraw sequences with their admission outcomes and notifications. Emoji cases separate UTF-8 wire bytes from character counts. |
| `room-authority-client.json` | `authority_client` | Manager identity and policy replies, steward grants, and room-publication identity derivation from stubbed replies. |
| `room-invitation-client.json` | `invitation_client` | Invitation receipts derived from fixture entropy, privacy and policy replies, and the exact calls the client makes. |
| `stewardship.json` | `stewardship` | The stewardship lifecycle: claim without management, taking authority, reconnect release, voluntary drop, stale and current revocation generations, and kick admission. |
| `bridge-client.json` | `bridge_client` | Bridge forms decoded and submitted, answers split into public values and transient secrets, their wire form, the calls made, and what the bridge says back. |
| `files-protocol.json` | `files` | The attachment prefix and exact readers: empty files, malformed and incomplete records, maximum record counts, UTF-16 name limits, integer and float distinctions, and image-dimension normalization. |
| `direct-client.json` | `direct_client` | The direct-message receiver: messages, reciprocal routes, typing, room and archive offers, UTF-8 line limits, and malformed attachment suffixes. Large strings use a text-repetition descriptor. |
| `direct-sources.json` | `sources` | Sender-hosted blob reads: chunk bounds, contiguous completion, failed delivery, empty files, and invalid read arguments. |
| `inbox-publication.json` | `inbox_publication` | Inbox alias and offer counts across two offerers, reuse, limit pressure, forget, and close, with the ordinary and IRC-front pool limits. Opaque alias strings are not compared. |
| `directory-client.json` | `directory_client` | Directory room lists, snapshots, events, and keys as the client reads them, the calls it makes, and room and manager link derivation. |
| `directory-view.json` | `directory_view` | The durable directory view across room updates, registration replacement, stale unregister notices, truncation, row limits, and contextual Unicode lowercase. |
| `registration-client.json` | `registration_client` | Registration arguments, name-voucher calls, registration-id acceptance, and control notifications. |
| `introduction-client.json` | `introduction_client` | Introduction traces: direct success, early and fresh offers, a stale banked offer, retry exhaustion, offline refusal, and malformed replies, replayed against the notification bank and retry policy. |
| `signaling-client.json` | `signaling_client` | Signaling reply admission and the relayed-signal byte limits, including the WebRTC description ceiling. SDP and ICE are bounded opaque text here. No channel is negotiated. |
| `archive.json` | `archive`, `archive_host` | Archive record and filter acceptance with canonical output: integer wire kinds, safe bounds, UTF-8 and UTF-16 limits, control characters, withdrawal, attachment shapes, digests, and malformed rows. |
| `archive-record-documents.json` | `archive_documents` | The archive record document as one file both readers read: the Rust proof and `apps/rooms/test/archive/record_document_test.ts` parse the same documents, so the two sides cannot drift apart. |
| `archive-disk.json` | `archive_disk` | Version-one JSONL archive files opened with a small capacity and compaction delta: acceptance, revision high-water marks, surviving records, torn-tail repair, snapshot gaps, malformed rows, a leading byte-order mark, and isolated surrogates. |
| `archive-recording.json` | `archive_recording` | Which messages become archive records under the recording policy, and the retention standings that follow. |
| `archive-shares.json` | `archive_shares` | Share documents before and after revocation, with the HMAC entropy for whole and scoped shares. |
| `archive-merge.json` | `archive_merge` | Merging archive accounts: withdrawal and edit precedence, current-writer and listed-order ties, standing records, and first-seen output order. |

## What a fixture does not prove

A fixture proves the pure contract. It does not stand in for the effects
around it, and the proofs say so where they stop: production blob storage,
durable shares, live inbox publication, three-party handoff, a real WebRTC
channel, and disk failure with restart are each covered by the native
`rooms-services` tests over real files and sockets, or by the browser proofs
in Chromium, not here. When a fixture's reader gains a case that only one
target exercises, the case belongs in that target's own test, not in the
shared document.
