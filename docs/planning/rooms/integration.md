# Rooms recursive resource integration

Status: active plan. The managed session is the production owner in the process
peer, browser workspace and access editor. The [session guide](../../rooms/session.md)
describes its storage, supervision and recovery; the
[effect contract](../../rooms/session-effects.md) describes its admitted effects.
This plan owns recursive room, directory and archive resource work in the
[ordered access plan](access-grants.md#ordered-implementation-and-exit-criteria).

## Shared prerequisite and remaining order

Fixed-resource schema registration, strong saved fields, bounded controls,
permission dependencies, kind applicability and trusted callback context are
implemented through the shared C/Rust/browser Loam profile. The
[C/Rust guide](../../loam/c-and-rust.md) and [browser guide](../../loam/browser.md)
define that profile's scope and evidence. General graph editing and privileged
owner lifecycle remain broader foreign-language projections.

Session declarations live in `rooms-application::content::session`. Their
Rust method and command enums generate browser metadata. Managed storage,
dispatch, typed clients and the editor consume the same declarations. The
session stores workspace, custody and receipts atomically and supervises exact
source-dependent workers on LMDB and IndexedDB.

Recursive resources need their own content schemas, applicability declarations,
operation requirements and interaction. Shared Zig remains the authority for
policy algebra, dependencies, ceilings, scope and lifecycle. Rust declares
application prerequisites and selected targets. UI containment cannot become a
second canonical-parent or authority map.

## Resource consumers and recovery

Paths below are relative to `apps/rooms/rust/`, except explicitly named
TypeScript paths. Each row covers its service, browser and focused proof
consumers together. Recovery requires held source/result authority. An ID,
nickname or failed access check cannot select a stronger method.

| Current resource owner | Required replacement |
| --- | --- |
| Private room recovery keys in `application/src/directory/creation.rs`, `application/src/session/checkpoint/commands/results.rs`, `services/src/server/rooms.rs`, `services/src/server/authority/queue/` | Retain idempotent creation intent through bounded creation receipts and publish exact independent ownership/access results. Delete recovery-by-name and broad link minting as remedies for limited admission. |
| Room manager/steward/entry generations in `services/src/server/authority.rs`, `services/src/server/document.rs`, `application/src/server/document.rs`, `services/src/server/links/` | Replace role-generation grant state with shared endpoints/controls. Keep room identity and discovery generation separate. Remove old room/steward/manager publication reconstruction and duplicate revocation ledgers. |
| Room live invitation in `application/src/server/invitation.rs`, `services/src/server/invitations.rs`, `glowcap/src/client/invitation.rs` | Replace with four-mode offers and atomic claim results. Keep receipt competition as behavior to prove; delete the fixed observer/participant and connection-only admission state. |
| Room invitation and rejoin in `runtime/src/rooms/`, `application/src/session/checkpoint/` | Managed continuing access must retain the exact accepted endpoint without an implicit room-link mint. Raw existing-link forwarding remains explicit direct sharing. |
| Nickname voucher in `services/src/server/registration.rs`, `application/src/server/directory/registry.rs`, `glowcap/src/client/directory/registration/` | Preserve one-use continuity and authenticated comparison from ADR-0142; add current grant/generation checks. A voucher replaces a registration, not the access grant. Never persist a connection voucher in a checkpoint. |
| Archive shares in `application/src/archive/shares/`, `runtime/src/archive/publications.rs`, TypeScript `apps/rooms/lib/archive/durable_protocol.ts` | Delete separate share lifecycle/ID storage and reuse managed exact-scope publications. Preserve archive records and blobs as content, with dependent readers and independent recording authority. |
| Operator capability state in `services/src/server/capabilities.rs`, `services/src/server/operations/` | Keep the separately held operator front and its existing ownership. Mediate attachment access with UseOperations; public directory fetch never exposes it. |

Generic Host retain/release, caretaker and attenuation remain protocol
mechanisms. Application scope checks and durable grant state belong to each
resource owner.

## Implementation and proof ownership

Follow the [phase order](access-grants.md#ordered-implementation-and-exit-criteria):
scoped recursive content and continuing room access, restricted directory access,
then the complete conversation workflow. The [editor contract](access-editor.md)
owns interaction; the [scenarios](scenarios.md) own complete design examples.
Deliver each phase through both runtime embeddings, typed clients, generated
metadata and the shared editor.

Each resource phase proves its scoped interaction, persistence, size and refusal
contracts before the next begins. Services and browser consumers use the same
owner. Replace unreleased contracts directly and delete exhausted owners with
their callers. Old or malformed stored state remains an explicit refusal;
reset is an operator action. OS portability and macOS acceptance remain
maintainer-owned.
