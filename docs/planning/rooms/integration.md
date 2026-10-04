# Rooms access consumers and recovery

Status: active plan. This phase 1 inventory links the
[operation matrix](authority.md) and [storage contract](persistence.md) to their
implementation owners. Paths describe current code to replace or adapt;
the shared Rooms integration remains unimplemented. The
[ordered plan](access-grants.md#ordered-implementation-and-exit-criteria)
owns prerequisites and implementation completion.

## Shared prerequisite and remaining order

Fixed-resource schema registration, policy edits, bounded managed children and
control attenuation are implemented through the C/Rust/browser Loam profile.
The [consumer guide](../../loam/c-and-rust.md) and
[browser proof](../../loam/browser.md) record scope and restart/refusal evidence
on a non-chat resource. This closes that shared helper prerequisite; it does
not replace any Rooms authority or complete phase 2.

The session declaration prerequisite is implemented in
[`rooms-application::content`](../../../apps/rooms/rust/application/src/content.rs).
Its scope is the version-one workspace payload, typed custody and effect-result
records, explicit permission keys, session presets and exhaustive requirements.
The existing Rust method and command enums generate their browser metadata in
[`session_content_data.ts`](../../../apps/rooms/lib/session_content_data.ts).
These declarations do not replace the session dispatcher, storage or editor.

The shared application contract proof at
[`content_session.rs`](../../../apps/rooms/rust/proofs/src/content_session.rs)
checks preset replacement, dependencies, method/command routing, bounded
payloads, exact custody generations and refusal of old bearer fields.
`rooms-rust-test` executes it on Linux; `rooms-rust-browser-test` executes the
same body in Deno and Chromium Wasm. Browser command tests exercise the generated
metadata, and `rooms-browser-metadata-check` detects drift.

The reference-field prerequisite is implemented through shared Zig and the
existing Host. The C/Rust/browser profile authors and restores strong fields,
protects the managed-resource binding and preserves exact grant authority.
A shared consumer trace checks transactional edits and cold restoration on
LMDB and IndexedDB; shared Zig scenarios own foreign-reference semantics.

[`session::records`](../../../apps/rooms/rust/application/src/content/session/records.rs)
implements the workspace, custody and effect codecs and their complete schema
registry. Portable proofs check ordered fragments, aggregate capacity, exact
slot/generation matching and original effect targets/results. The Linux proof
opens Loam with all three schemas. This closes the field and codec prerequisite;
production snapshot staging and startup adoption remain in the combined
replacement below.

Permission dependencies are enforced by the persisted shared policy descriptor
([ADR-0190](../../decisions/adr/ADR-0190-declarative-permission-dependencies.md)).
`rooms-glowcap::policy` projects the full Rooms vocabulary and its declared
prerequisites. Direct issuance, derivation, policy edits and control ceilings
refuse invalid terms; effect requirements remain partial demands. Zig owns the
closure and intersection scenarios. Rust/LMDB and Chromium/IndexedDB use one
wire trace before and after cold restoration, and the Rooms descriptor proof
runs on Linux and in the async Wasm embedding. Browser contracts now belong to
`check-external` and run in CI. This closes the dependency prerequisite only.

Remaining order:

1. Project scope-aware interface applicability at every issuance and policy
   edit, plus exact target context for content admission and deferred effects.
   Direct derivation must not bypass interface support. Define applicability
   for heterogeneous selections and future descendants before enforcing it.
   Keep history constraints on the canonical upstream conversation/generation;
   the session's History permission is only an additional projection gate.
   Recovery rechecks the original effect target, and returned files check both
   session and upstream authority. Imports add ManageCustody; releasing local
   custody requires no working upstream grant.
2. Project application management through the shared model: expected revisions,
   labels, control-owned issuance, explicit Inspect/Issue/Edit/DelegateControl
   powers and bounded branch inventory. Fixed-resource lifecycle controls do
   not supply these operations. Generate consumer metadata at their owner.
3. Replace session persistence, publication restoration, runtime admission,
   browser consumers and the editor together, with the deletions below. Stage
   the complete codec page graph, strong custody and resource binding atomically;
   register all schemas at startup and admit physical transaction capacity. Prove
   the phase's complete application behavior before advancing to recursive rooms.

General graph editing follows with recursive content. Session declarations
contain no duplicate canonical-parent map or JSON authority ledger. Shared
Zig continues to own policy algebra, dependencies, ceilings, scope and lifecycle;
Rust declares application prerequisites and exact target requirements.

## Consumer map

Paths below are relative to the repository root. Directory rows name the whole
consumer family, including its focused tests. Implementation must update both
service and Wasm users in the same slice, with generated metadata as the sole
mirror of policy and method declarations.

| Consumer | Current paths | Required change |
| --- | --- | --- |
| Shared policy/content | `apps/rooms/rust/application/src/grants/`, `room/`, `directory/`, `files/`, `archive/`, `session/` | Declare typed Rooms requirements, presets and application schemas. Establish `content` within this crate; replace the session-specific grant model with the Zig binding. |
| Directory/room services | `apps/rooms/rust/services/src/server/behavior.rs`, `registration.rs`, `signaling.rs`, `seat.rs`, `files.rs`, `lines.rs`, `invitations.rs`, `authority.rs` | Compose shared admission and content transactions; serve dependent facets and intentionally public entry points. Move reusable execution into runtime rather than copying it. |
| Session enforcement | `apps/rooms/rust/runtime/src/service/facet.rs`, `service/authority.rs`, `service/verbs/`, `grants/`, `session/commands/` | Replace tier checks with per-method/command requirements; keep exact attachment mediation and scoped cancellation. |
| Membership/rejoin | `apps/rooms/rust/runtime/src/rooms/worker/joining.rs`, `worker/custody.rs`, `worker/retirement.rs`, `rooms/entry.rs`, `rooms/offers.rs` | Retain accepted access, create a fresh seat on rejoin and cancel old seat work. Remove recovery through a stronger entrance. |
| Directory routes | `apps/rooms/rust/runtime/src/directories/`, `apps/rooms/rust/glowcap/src/client/directory/` | Bind discovery, registration/vouchers, peering and signaling to exact directory grants. Distinguish authority loss from unreachable independent rooms. |
| Direct/foreign custody | `apps/rooms/rust/runtime/src/direct/`, `archive/`, `apps/rooms/rust/services/src/session_runtime/` | Keep actual held upstream references through handoffs and archive facets. Shared-process location cannot supply owner authority. |
| Typed clients | `apps/rooms/rust/glowcap/src/client/session/`, `client/room/`, `client/manager.rs`, `client/stewardship.rs`, `client/invitation.rs`, `client/archive/` | Generate common managed clients; encode explicit terms/modes and parse typed refusal/status/recovery results. |
| Browser runtime | `apps/rooms/rust/browser/src/attached/sharing.rs`, `attached/history.rs`, `attached/files.rs`, `attached/observation.rs`, `workspace_persistence.rs` | Preserve exact grant and source through awaits and saved custody. Invitation gestures take policy and lifetime, not just conversation and nickname. |
| Browser/process storage | `apps/rooms/rust/browser/src/storage/`, `apps/rooms/rust/platform/src/storage/`, `apps/rooms/rust/services/src/session_state.rs` | Realize shared Loam transactions and recovery outcomes. Keep tab-live owners explicit; no JSON grants sidecar. |
| Session UI | `apps/rooms/web/ui/settings/SessionAccess.tsx`, `SessionGrantEdit.tsx`, `ArchiveShares.tsx`, `apps/rooms/lib/session/grants.ts`, `access_view.ts`, `facet.ts`, `client.ts` | Use scoped inventory, explicit policy groups and separate controls. Remove observe/interact/admin as the policy engine. |
| Room/content UI | `apps/rooms/web/ui/cards/RoomAccess.tsx`, `apps/rooms/web/ui/session/`, `apps/rooms/web/ui/controller/` | Add item sharing, exact admission choices, accepted-access status, source-aware navigation and audience preview. Existing presence is not an offline grant inventory. |
| TypeScript protocol users | `apps/rooms/lib/protocol.ts`, `protocol_operator.ts`, `protocol_handover.ts`, `archive/protocol.ts`, `archive/durable_protocol.ts`, `archive/blob_protocol.ts`, `session/verbs.ts` | Reference generated shared interfaces; replace duplicate lifecycle/share policy, retain content/transport contracts. |
| Terminal clients | `apps/rooms/clients/deno/client.ts`, `python/room_client.py`, `racket/room-client.rkt`, `rust/client.rs`, `zig/client.zig` | Exercise exact invites, constrained seats and current access on baseline Syrup. Unsupported access methods return unavailability; no privileged retry. |
| Product commands | `apps/rooms/rust/product/src/bin/rooms-chat.rs`, `rooms-session.rs`, `rooms-session/commands/`, `rooms-server.rs`, `rooms-archive.rs`, `rooms-web.rs`, `rooms-irc-front.rs`, `rooms-irc-bridge.rs` | Expose exact sharing/admission/status through existing fronts and session bootstrap. Startup registers schemas, storage limits and owner publication listeners; no command revives old grant documents. |
| IRC bridge | `apps/rooms/rust/services/src/server/irc/`, `apps/rooms/rust/application/src/server/irc/`, `apps/rooms/lib/protocol_irc.ts` | Declare bridge-specific supported requirements. Lack of files/topic support refuses that policy rather than giving a misleading preset. |
| Protocol generation | `tools/gen/rooms_protocol.zig`, `tools/gen/rooms_protocol/`, generated `protocol_data` and terminal `protocol_gen` files | Generate managed interfaces from their shared schema; reference them from Rooms grammar. Check exhaustive methods, commands and returned capabilities. |
| Proofs | `apps/rooms/rust/proofs/src/`, `apps/rooms/test/`, `apps/rooms/rust/services/src/server/tests/`, `apps/rooms/rust/services/src/grant_publications/tests.rs` | Replace tier/role expectations with typed policy, crash, pressure and stale-derived-capability proofs. Preserve baseline outside-peer coverage. |

## Recovery routes and removals

Recovery is authorized by the held source/result capability, not by a resource
ID or nickname. Lost replies keep the original request identity and intent.
No client retries through a stronger method after an access refusal.

| Present route and paths | Replacement and exact deletion |
| --- | --- |
| Session ledger in `application/src/grants.rs`, `grants/model.rs`, `grants/storage.rs`, `grants/shared.rs`, `grants/protocol.rs`; service `services/src/grant_commands.rs`, `grant_publications.rs`; shared `runtime/src/grants/` | Delete the session-specific ledger, JSON codec, tier parser, grant-link derivation and bulk publication restoration. Common access records and exact endpoint publications replace them. Retain unrelated command/effect execution at its existing owner. |
| Process grants document in `application/src/documents.rs`, `services/src/session_state.rs`, `services/src/session_directory.rs` | Remove Grants document enumeration and `grants.json` reads/writes from session startup. Store retains the authority/content owner atomically; workspace exports cannot restore its grant authority. |
| `runtime/src/grants/publications.rs` eagerly restoring the active grant set | Register shared on-demand publication discovery. Startup loads bounded owner state; exact descriptor restoration follows a held publication. |
| Private room recovery keys in `application/src/directory/creation.rs`, `session/checkpoint/commands/results.rs`, `services/src/server/rooms.rs`, `server/authority/queue/` | Retain idempotent creation intent through bounded creation receipts and publish exact independent ownership/access results. Delete recovery-by-name and broad link minting as remedies for limited admission. |
| Room manager/steward/entry generations in `services/src/server/authority.rs`, `server/document.rs`, `application/src/server/document.rs`, `server/links/` | Replace role-generation grant state with shared endpoints/controls. Keep room identity and discovery generation separate. Remove old room/steward/manager publication reconstruction and duplicate revocation ledgers. |
| Room live invitation in `application/src/server/invitation.rs`, `services/src/server/invitations.rs`, `glowcap/src/client/invitation.rs` | Replace with four-mode offers and atomic claim results. Keep receipt competition as behavior to prove; delete the fixed observer/participant and connection-only admission state. |
| Browser `attached/sharing.rs`, runtime `service/verbs/invitations.rs`, `rooms/worker/joining.rs`, application checkpoint invitation gestures | Remove the implicit `ensureRoomLink` fallback for managed invites/rejoin. Save the exact accepted continuing endpoint; raw existing-link forwarding remains explicit direct sharing. |
| Nickname voucher in `services/src/server/registration.rs`, `application/src/server/directory/registry.rs`, `glowcap/src/client/directory/registration/` | Preserve one-use continuity and authenticated comparison from ADR-0142; add current grant/generation checks. A voucher replaces a registration, not the access grant. Never persist a connection voucher in a checkpoint. |
| Archive shares in `application/src/archive/shares/`, `runtime/src/archive/publications.rs`, TypeScript `lib/archive/durable_protocol.ts` | Delete separate share lifecycle/ID storage and reuse managed exact-scope publications. Preserve archive records and blobs as content, with dependent readers and independent recording authority. |
| Session volatile `service/verbs/delegation.rs` and `service/views.rs` | Delete independent delegate counters and revocation authority in favor of shared live grant/control records. Keep view delivery and attachment custody scoped to the grant. |
| Workspace/checkpoint room links in `application/src/session/checkpoint/`, runtime `rooms/intent.rs` and browser `workspace_persistence.rs` | Separate intent from typed authority fields. Delete any reconstruction that derives stronger authority from display names. User-imported bearers remain deliberate imports, validated as exact saved roles. |
| Operator capability state in `services/src/server/capabilities.rs`, `server/operations/` | Keep the separately held operator front and its existing ownership. Mediate attachment access with UseOperations; public directory fetch never exposes it. |

Rows name deletions required in the owning implementation slice, not files
removed by this design change. Generic Host retain/release, caretaker and
attenuation mechanisms remain protocol mechanisms. They cannot replace
application scope checks or durable grant state.

## Integration order and proof ownership

The first implementation slice replaces session access only after the process
checkpoint, C/Rust projection, and browser execution/storage proof. It updates
services, browser-hosted sessions, typed clients, UI, generated grammar,
and proofs together. The [editor](access-editor.md) owns interaction; the
[scenario walkthroughs](scenarios.md) own the end-to-end design examples.

The next slices implement scoped recursive content and continuing room access,
then restricted directory access, then full conversation workflows and outside
peers. Delete each replaced mechanism when its slice lands. There is no dual
ledger, compatibility re-export, schema migration, or fallback reader. Old
prerelease owner storage is rejected with an explicit operator reset path;
startup never deletes data or loads authority more broadly to keep running.

Application proofs establish requirement mappings and content identities.
Shared Zig proofs establish policy algebra, dependency and lifecycle behavior.
Runtime proofs exercise held returned capabilities, pending work and storage
recovery. UI proofs establish committed feedback, conflicts, keyboard focus and
exact retained access. Outside-peer proofs establish ordinary CapTP capability
handoff over baseline Syrup; a Rust consumer does not define Zig semantics.
