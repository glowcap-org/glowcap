# Decision records

These records explain the enduring choices behind glowcap's current design.
Read [the architecture guide](../architecture.md) for the layer tour and
[known limitations](../boundaries.md) for present gaps.

## Writing a decision

Write an ADR when changing the choice would be costly, a reader would need
context to understand it, and credible alternatives explain why it was chosen.
A bug fix, local refactor, naming cleanup or measurement alone needs no record.
Extend the owning record when the underlying choice remains the same.

Use [the template](adr/template.md). State the constraint, choice, rejected
alternatives, consequences and relevant evidence. Keep procedures in their
owning guide and implementation detail beside the code. An accepted design is
not a claim that every consumer or deployment has been verified.

The frontmatter owns standing: `proposed`, `accepted` or `superseded`. Accept a
new architectural contract before building against it. Its date records
the proposal, acceptance or latest consolidation. Proposed work remains linked from the
[roadmap](../roadmap.md).

After publication, keep identifiers stable. A superseded record retains its
number and a reciprocal `superseded_by`/`supersedes` relation. A refinement uses
`amends`/`amended_by` instead. `source-check` validates those relations and the
record's id, filename and status. The prerelease consolidation is disclosed in
[provenance](../../PROVENANCE.md).

## Records by subject

### Protocol and execution

- [ADR-0001 Codec profiles and negotiation](adr/ADR-0001-codec-profiles-and-negotiation.md)
- [ADR-0002 Session handshake and bootstrap](adr/ADR-0002-session-handshake-and-bootstrap.md)
- [ADR-0003 Promise pipelining and listeners](adr/ADR-0003-promise-pipelining-and-listeners.md)
- [ADR-0004 Baseline wire interoperability](adr/ADR-0004-baseline-wire-interoperability.md)
- [ADR-0005 Passable value model](adr/ADR-0005-passable-value-model.md)
- [ADR-0006 Receiver-perspective references](adr/ADR-0006-receiver-perspective-references.md)
- [ADR-0007 Sturdyrefs and publication](adr/ADR-0007-sturdyrefs-and-publication.md)
- [ADR-0008 Session resource limits](adr/ADR-0008-session-resource-limits.md)
- [ADR-0009 Performance budgets](adr/ADR-0009-performance-budgets.md)
- [ADR-0010 Cap'n Proto wire profile](adr/ADR-0010-capnp-wire-profile.md)
- [ADR-0011 Compiler-enforced layers](adr/ADR-0011-compiler-enforced-layers.md)
- [ADR-0012 Stream framing and admission](adr/ADR-0012-stream-framing-and-admission.md)
- [ADR-0013 C allocation and frame ownership](adr/ADR-0013-c-allocation-and-frame-ownership.md)
- [ADR-0014 Actor execution and lifetime](adr/ADR-0014-actor-execution-and-lifetime.md)
- [ADR-0015 Persistent collections and time travel](adr/ADR-0015-persistent-collections-and-time-travel.md)
- [ADR-0016 Capability forwarding](adr/ADR-0016-capability-forwarding.md)
- [ADR-0017 Outbound pressure and fairness](adr/ADR-0017-outbound-pressure-and-fairness.md)

### Runtime and foreign interfaces

- [ADR-0018 One Host I/O runtime](adr/ADR-0018-one-host-io-runtime.md)
- [ADR-0019 Pooled completion I/O](adr/ADR-0019-pooled-completion-io.md)
- [ADR-0020 Linux completion backends](adr/ADR-0020-linux-completion-backends.md)
- [ADR-0021 Iroh transport sidecar](adr/ADR-0021-iroh-transport-sidecar.md)
- [ADR-0022 Composable C archives](adr/ADR-0022-composable-c-archives.md)
- [ADR-0023 Binding archive resolution](adr/ADR-0023-binding-archive-resolution.md)
- [ADR-0024 Transport providers and archive contracts](adr/ADR-0024-transport-provider-and-abi-contracts.md)
- [ADR-0025 Capability release](adr/ADR-0025-capability-release.md)
- [ADR-0026 Host-scoped capability identity](adr/ADR-0026-host-scoped-capability-identity.md)
- [ADR-0027 Wire retains and export admission](adr/ADR-0027-wire-retains-and-export-admission.md)
- [ADR-0028 Session and durable peer authentication](adr/ADR-0028-session-and-durable-peer-authentication.md)
- [ADR-0029 Dial and accept plans](adr/ADR-0029-dial-and-accept-plans.md)
- [ADR-0030 Failure and close policy](adr/ADR-0030-failure-and-close-policy.md)
- [ADR-0031 Structured diagnostics](adr/ADR-0031-structured-diagnostics.md)
- [ADR-0032 CLI and product boundaries](adr/ADR-0032-cli-and-product-boundaries.md)

### Reachability and observation

- [ADR-0033 Byte-transparent relays](adr/ADR-0033-byte-transparent-relays.md)
- [ADR-0034 Browser peers](adr/ADR-0034-browser-peers.md)
- [ADR-0035 WebRTC exchange ownership](adr/ADR-0035-webrtc-exchanges.md)
- [ADR-0036 Identity and multihome routing](adr/ADR-0036-identity-and-multihome-routing.md)
- [ADR-0037 Peer-chosen table keys](adr/ADR-0037-peer-chosen-table-keys.md)
- [ADR-0038 Local positions and table identity](adr/ADR-0038-local-position-tables.md)
- [ADR-0039 Session-owned handoff authority](adr/ADR-0039-session-owned-handoff.md)
- [ADR-0040 Trace observation authority](adr/ADR-0040-trace-observation-authority.md)
- [ADR-0041 Sealed byte channels](adr/ADR-0041-sealed-byte-channels.md)
- [ADR-0042 Onion interoperability](adr/ADR-0042-onion-interoperability.md)

### Rooms

- [ADR-0043 Rooms identity and authority](adr/ADR-0043-rooms-identity-and-authority.md)
- [ADR-0044 Member-owned archives](adr/ADR-0044-member-owned-archives.md)
- [ADR-0045 Managed Rooms sessions](adr/ADR-0045-managed-rooms-sessions.md)

### Persistence and managed access

- [ADR-0046 Resource scopes and permissions](adr/ADR-0046-resource-scopes-and-permissions.md)
- [ADR-0047 Prepared grant mutations](adr/ADR-0047-prepared-grant-mutations.md)
- [ADR-0048 Loam persistence foundation](adr/ADR-0048-loam-persistence-foundation.md)
- [ADR-0049 Record-backed hosting](adr/ADR-0049-record-backed-hosting.md)
- [ADR-0050 Transactional reclamation](adr/ADR-0050-transactional-reclamation.md)
- [ADR-0051 Application capacity and residency](adr/ADR-0051-application-capacity-and-residency.md)
- [ADR-0052 Managed owner lifecycle](adr/ADR-0052-managed-owner-lifecycle.md)
- [ADR-0053 Returned capability authority](adr/ADR-0053-returned-capability-authority.md)
- [ADR-0054 Scoped change observation](adr/ADR-0054-scoped-change-observation.md)
- [ADR-0055 Offline LMDB replacement](adr/ADR-0055-offline-lmdb-replacement.md)
- [ADR-0056 Loam foreign and browser execution](adr/ADR-0056-loam-foreign-and-browser-execution.md)
- [ADR-0057 Retained content pages](adr/ADR-0057-retained-content-pages.md)
- [ADR-0058 Transactional turn sends](adr/ADR-0058-transactional-turn-sends.md)
- [ADR-0059 Rooms retention storage](adr/ADR-0059-rooms-retention-storage.md)
- [ADR-0060 Completion submission and parking](adr/ADR-0060-completion-submission-and-parking.md)
- [ADR-0061 Storage engine contract](adr/ADR-0061-storage-engine-contract.md)
- [ADR-0062 SQLite as the default disk engine](adr/ADR-0062-sqlite-default-storage.md)

### Wire representation

- [ADR-0063 Frame-owned argument views](adr/ADR-0063-frame-owned-argument-views.md)
- [ADR-0064 Borrowed outbound encoding](adr/ADR-0064-borrowed-outbound-encoding.md)
- [ADR-0065 Next-profile operations](adr/ADR-0065-next-profile-operations.md)

### Maintainer workflow

- [ADR-0067 Evidence-bearing integration](adr/ADR-0067-evidence-bearing-integration.md)

### Proposed

- [ADR-0066 Proposed TypeScript runtime](adr/ADR-0066-proposed-typescript-runtime.md)
