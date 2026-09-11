# Rooms migration fixtures

These version-one documents were written by the historical TypeScript session
implementation using its in-memory document adapter.
They are retained migration inputs, not Rust-generated expectations.

- `grants-v1.json` contains an interact grant issued with label ` Phone ` and
  no access to earlier history.
- `grants-suspended-v1.json` suspends that grant with the note `Away` and
  retains a revoked observe grant as a tombstone.
- `grants-surrogate-v1.json` additionally records an observe grant whose
  label is one isolated high surrogate, U+D800. The JavaScript schema accepts
  this value; a Rust translation must preserve it through a document rewrite.

The root entropy used to capture the derivation vector is sixteen bytes of
`0x5a`. Grant `00000000-0000-4000-8000-000000000001` produces the sixteen-byte
entropy `9809158594ada38da41f23b20c34dbb7` through that implementation.
This is synthetic test material and carries no deployed authority.

`room-protocol.json` was captured from the historical TypeScript line behavior
and `lib/room/policy.ts`'s policy reader. It records all eight mode combinations,
public offers, current line/file limits, and line-edit/withdraw call sequences
with their admission outcomes and emitted notifications. The line actor used
a collecting subscriber and no files or retained history. The emoji boundary
cases distinguish UTF-8 wire bytes from JavaScript character counts. Integers
in captured notifications use `{ "integer": "7" }` to retain their wire type;
this notation is fixture data, not a new Rooms encoding.
The same fixture captures `lib/room/message.ts`'s actual `readLineId` and
`readLineChange` outputs for integer/number values, their safe-integer bounds,
unknown tags, missing ids, and malformed values. The Rust producer's changes
are also passed through the shared Rust marker reader. This proves marker
agreement, not full inbox admission or attachment decoding.

Refiling, resource retirement, and refused staging are separate Rust scenarios;
this capture does not claim to have exercised those paths in TypeScript.

`files-protocol.json` captures the existing `lib/attachment.ts` prefix and exact
readers, with synthetic objects of the binding's `Ref` class. It includes empty
files, truncated dimensions, malformed suffixes, maximum record counts, UTF-16
name limits, integer/float distinctions, and image-dimension normalization.
The file's limit snapshot comes from `lib/limits.ts`. Its `{ "capability": true }`
values stand for synthetic parser inputs; they confer no authority and are not
a Rooms encoding. Rust file-store scenarios separately cover staging, aggregate
and per-room pressure, cancellation, alias expiration, and line integration.

`failures.json` records every exported failure code and the actual
`lib/errors.ts` `RoomError.from` result for bare, prefixed, unknown, and nested
reasons. The machine-readable code is the compatibility contract; human detail
may change. Native file calls exercise these classifications through the real
binding's broken-promise carrier as well.

`session-documents.json` captures the existing document ceilings and
`decodeSessionDocument` outputs for ordinary UTF-8, byte-order marks, and
malformed bytes. Native filesystem tests use the existing grant fixtures too;
they restore and rewrite revoked and isolated-surrogate records through the
real document store.
The existing file store also decodes before returning bytes, so the native
grant path accepts two initial byte-order marks while direct document decoding
consumes one. Native and shared tests preserve those distinct boundaries;
the existing file-backed grant owner was exercised with zero through three marks.

`grant-commands.json` captures the current `dispatchGrantCommand` against the
real TypeScript grant ledger for all four access levels, issue/retry/conflict,
policy patches, suspension-note clearing, and revocation. Views contain a
fixture publisher's stable URI; native tests separately exercise the actual
Rooms v1.0 URI format through glowcap. Capability custody is tested with owned
argument guards rather than encoded as JSON authority.

`checkpoints.json` captures 94 cases from the historical TypeScript checkpoint
parser and redactor, including missing fields, nullable/optional normalization,
relationships, route authorities, WebSocket URLs and UTF-16 surrogate text.
Expected documents are encoded strings so the fixture reader never substitutes
Unicode scalar values for isolated surrogates. Bridge-answer insertion order is preserved: the durable retry ledger hashes
material that includes checkpoint JSON. The
redactor includes the fix that removes room bearer links independently of
bridge intent, backed by `checkpoint_redaction_test.ts`. Native tests verify
captured route facts through the real binding; the portable scenario consumes
those facts without implementing another locator parser.

`session-events.json` captures 83 TypeScript event-reader decisions: header and
integer bounds, mutation identity, archive coordinates, presence and room facts,
including escaped JSON tags, isolated UTF-16 surrogates, nulls and positional
arrays. The shared proof additionally checks that a valid attachment guard
outlives delivery and that malformed metadata or a later malformed attachment
leaves no retained guards. Capability custody uses live test guards rather than
JSON substitutes; the capture itself contains no accepted file capabilities.

`snapshots.json` captures 86 TypeScript snapshot-reader cases, all four facet
projections and the existing overflow degradation order. Integer wire values
use the fixture-only `{ "integer": "7" }` form. JSON payload fields remain
strings, including lossless surrogate cases. Large overflow inputs are rebuilt
from bounded typed rows by the proof; only their expected answers are stored.
Rust additionally rejects aggregate inbound overflow before retention and drops
live JSON that exceeds its individual reader limit. Native tests construct and
read the binding's real argument types; production watch delivery is not part
of this fixture.

`operator-views.json` captures 48 operator page cases, one complete inventory,
32 JSON inventory cases and 18 operations responses from the TypeScript readers.
They cover all seven row categories, member bounds, issued stewardship relations,
decimal revisions, listener relationships and bridge gateway records. Nested
objects reject positional arrays; JSON display text preserves isolated surrogates.
The native room-server scenarios additionally submit real inventories to the
shared reader. The session relay scenario uses the typed client for snapshot,
page, retire and listener reads.

`session-state.json` captures 38 durable checkpoint/effect document cases and a
17-action trace from the historical TypeScript state owner. The trace records
exact writes, retry/refusal outcomes and revisions. Action objects are encoded
JSON strings to preserve isolated UTF-16 surrogates in ids and hash material.
A large embedded checkpoint exercises the durable envelope's byte ceiling
independently of the smaller standalone checkpoint wire limit. Rust scenarios
also inject unchanged/indeterminate failures and cancellation, and restore
after each result write to prove convergence without repeated external work.

`session-commands.json` captures 113 command cases and four room offers from the
historical `session/commands.ts` owner and its join/peering helpers. The tests compare acceptance,
exact resulting checkpoints, impact and retry material, with a successful case
for every pure command. They cover multiple directories and rooms, cascading
retirement, invitations, explicit rejoining, stale authority generations,
bridge scope propagation and UTF-16 input. Secrets are excluded from retry
material. Native tests check route authorities and generation tokens through
the binding, including the existing UTF-8 decoder's leading-BOM behavior.

`session-results.json` captures 38 preparation, 45 application and 12 resume
cases from the historical result-command owner. Intent and result JSON remain encoded
strings. The same native/browser body also drives each result kind through the
durable state engine, with uninterrupted execution and restart at every write.
These prove pure policy and recovery, not the external calls that obtain room
authority. Native storage separately rejects stale new plans before writing
and refuses unknown or malformed pending plans on load without rewriting them.

`reconciliation.json` captures 59 cases from the historical state-sync owner, followed
by the validation and equality check used by durable reconciliation. An equal
candidate is recorded as no change. The cases include stale routes and tokens,
room retirement isolation, acquired authority conflicts, publication versions,
reconnect results, direct registration admission and collection limits. Fact
objects remain encoded JSON strings so surrogate values survive fixture loading.
Rust tests also replay every changed fact to check idempotence. Native queue
tests separately cover ordered retries, count/byte pressure, command progress
during backoff, unsent admissions, shutdown and cancellation during disk work.

`session-command-admission.json` captures the real session command dispatcher's
access and envelope checks, stopping at a stubbed mutation boundary. It records
argument-count, UTF-16, encoded-byte and revision limits; it does not execute
external effects or establish per-command argument validity. Large inputs use
text/repetition descriptors, and integers retain their wire kind. The same file
captures handed-invitation receipt followed by acceptance through both existing
checkpoint reducers, including intermediate validation and failure cases. Rust
runs these cases natively and in browser Wasm; native storage separately proves
atomic failure, one commit and retry after the transient handoff disappears.

`room-authority-client.json` captures manager identity and policy replies,
steward grants and room-publication identity derivation from the existing
TypeScript clients. These captures use stubbed capability replies; native and
browser tests compare shared Rust acceptance and derived identities. Native
client tests separately exercise the real Rust Host, exact method arguments,
malformed replies and shared-connection custody. They do not replace the
production room actors or prove browser Host portability.

`stewardship.json` captures 24 lifecycle actions from `RoomStewardship`, including
claim without management, taking authority, reconnect release, voluntary drop,
stale and current revocation generations, and kick admission. Shared Rust also
tests owner-bound acquisition tickets, cancellation, candidate disposal and
cross-room isolation. Native tests separately drive these clients through real
Host calls, including deferred replies during revocation and cancellation.

`registration-client.json` captures registration arguments, name voucher calls,
registration-ID acceptance and control notifications from the existing
`DirectoryRegistration`. Shared Rust also exercises bounded notification queues
and capability custody independently of acknowledgement. Native CapTP scenarios
cover cancellation, replacement, timeout and closure with controlled actors;
these actors do not implement production names or reconnect persistence.

`introduction-client.json` captures seven `Directory.introduceVia` traces: direct
success, early and fresh offers, a stale banked offer, retry exhaustion, offline
refusal and malformed capability replies. Shared Rust replays the trace against
its notification bank and retry policy. Additional cases cover queue pressure,
cancelled and foreign-owner wait tickets, bank eviction and registration-ID
isolation. Native TCP tests separately prove actual three-party transfer and the
exporter connection needed for reciprocal calls; browser Host and signaling
integration remain separate work.

`signaling-client.json` captures actual `DirectorySignaling` reply admission and
`relayedSignalFits` byte limits, including the WebRTC ABI description ceiling.
Shared Rust also checks independently settled acceptance/answer milestones,
late replies, terminal failure and queue overflow. Native capabilities exercise
outbound exchange ownership and the answering inbox. The protocol treats SDP
and ICE as bounded opaque text; these tests do not negotiate a WebRTC channel.

`direct-client.json` captures the actual `directMessageReceiverBehavior` parser
with all optional receivers supplied. It covers messages, reciprocal routes,
typing, room/archive offers, UTF-8 line limits and malformed attachment suffixes.
Large strings use text/repetition descriptors. Capability and integer markers
are synthetic parser inputs. Shared Rust also checks borrowed text and exact
retention of admitted occurrences. Native tests separately exercise actual
capability routes, unsupported receivers and deferred failure; this capture
does not implement production direct-inbox publication or durable message storage.

`direct-sources.json` captures sender-hosted blob calls created by the actual
TypeScript `sendWithAttachments`. It records chunk bounds, contiguous completion,
failed delivery, empty files and invalid read arguments. Synthetic asynchronous
readers generate only requested chunks. Additional Rust scenarios cover budget
pressure, cancelled read leases and ownership retirement. Native tests separately
exercise file capabilities, deferred reads, short replies and pending-read shutdown.

`inbox-publication.json` captures alias and offer counts from the actual
TypeScript `inboxPublisher` across two offerers, reuse, limit pressure, forget
and close, along with the ordinary and IRC-front pool limits. Opaque alias
strings are not compared. Shared Rust fills and retires the captured IRC pool
across separate scopes. It additionally pins
retirement failure/retry, scope identity and immediate refusal after scope closure.
Native TCP tests separately exercise real Host aliases and directory reconnect,
including refusal of collisions with unrelated mutable Host publications.

`directory-view.json` captures the actual `DurableDirectoryView` across room
updates, registration replacement, stale unregister notices and truncation.
Shared Rust additionally checks row limits, independent directory views,
contextual Unicode lowercase, offers-only changes and replacement at capacity.
The last two cases intentionally improve notification and admission behavior.
Native tests separately compose discovery and registration with durable session
state; this capture does not prove the production session dispatcher.

`archive.json` captures record/filter acceptance and canonical output from
`lib/archive/protocol.ts` (`parseArchiveRecord`, `archiveRecordRow`,
`parseArchiveFilter`, `archiveFilterRow`). Inputs include integer wire kinds,
JavaScript-safe bounds, UTF-8/UTF-16 limits, control characters, withdrawal,
attachment shapes, digests and malformed rows. Shared Rust separately exercises
index identity, chronology, restore atomicity, capability custody, monotonic scope
and bounded scans. The cursor-ahead improvement is an explicit Rust scenario,
not a claim captured from TypeScript. Native TCP tests use a fixture archive;
these proofs do not cover production blob storage or durable shares.

`archive-disk.json` captures `FileArchiveBackend` opening version-one JSONL
files with capacity three and compaction delta two. It records acceptance,
revision high-water marks, surviving records, physical torn-tail repair and
explicit UTF-16 vectors for IDs, text and attachment names. Cases cover snapshot
gaps, tail continuity, chronology, malformed rows, safe numeric spellings,
withdrawal, a leading BOM and isolated surrogates. Rust replays this static
capture natively and in browser Wasm without invoking Deno. Additional Rust
scenarios cover invalid UTF-8 bytes, bounded snapshot encoding and wire-only
replacement of isolated surrogates. Native filesystem tests exercise the actual
journal backend; blob storage and durable shares remain outside this capture.

`archive-shares.json` captures the actual TypeScript share issuer's version-one
documents before and after revocation, plus HMAC entropy for whole and scoped
shares, including isolated UTF-16 units. Native and Wasm replay the capture.
Additional Rust proofs cover capacity, retry/conflict, immutable revoked IDs,
and unchanged versus indeterminate storage outcomes. Native filesystem tests
exercise the serial archive owner; native TCP tests separately cover durable publication and descendant revocation.

`archive-merge.json` captures `lib/archive/merge.ts`'s actual
`mergeArchiveAccounts` output. Cases cover withdrawal/edit precedence,
current-writer ties, listed-order ties, standing records, full identity and
first-seen output order. Native and Wasm replay record and keeper attribution.
Separate Rust scenarios verify borrowed winner identity and input bounds that
charge duplicate rows and empty accounts; no Deno process runs during replay.

The historical `authority` paths in `archive-disk.json` and `archive-shares.json`
name the TypeScript owners at capture time. Those owners are retired. Native
`archive::file` tests now exercise the journal, blob accounting, custody and
share publication against these inputs. Unsupported schemas report both
versions without modifying the original archive.
