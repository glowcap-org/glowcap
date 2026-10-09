# Managed access coverage

Managed access is Loam's layer for resources, grants, and the references that
use and control them. Native Zig exposes it as `glowcap.loam.access`. Owner
retirement and terminal cleanup are described under
[resource models](../shipped.md#resource-models). C and Rust project fixed-resource creation,
managed registration, shared-policy descriptors, storage completions and held
use/control capabilities, managed children, policy edits, control attenuation
and strong reference fields. A shared LMDB/IndexedDB trace checks transactional
field authoring, exact and dependent disclosure, removal and cold restoration.
General graph and owner APIs remain outside that profile.

**Resource graph.** `glowcap.loam.access.core` holds bounded resource graphs
with owner and generation identity, reparenting that refuses cycles, and
exact, selected, or subtree scope evaluation. Graph mutations check revisions
and allocate only at initialization
([resource structure](../decisions/adr/ADR-0153-access-resource-core.md)).

**Grant ledger.** One current path governs delegation, editable terms and lifecycle
([grant lifecycle](../decisions/adr/ADR-0154-access-local-grant-lifecycle.md)).
Persisted [permission dependencies](../decisions/adr/ADR-0190-declarative-permission-dependencies.md) and
[scope applicability](../decisions/adr/ADR-0197-scope-aware-permission-applicability.md) constrain terms and control ceilings.
Effects check exact targets. Callbacks receive canonical resource context; unsigned bounds and immutable ceilings constrain authority.

- A successful mutation returns owned change events. A failed or unchanged
  request produces none.
- A prepared write reserves its scope and keeps its inputs until an exact
  completion ([prepared writes](../decisions/adr/ADR-0155-access-prepared-grant-writes.md)).
  An unknown storage outcome blocks protected access until it is resolved.

**Use and control references.** Native opaque use and control references each
carry authority over one committed grant. Controls enforce independent
lifecycle powers and copied management ceilings, through the same
prepared-write path
([native grant capabilities](../decisions/adr/ADR-0156-access-native-grant-capabilities.md)).
Resident and durable bindings share control powers and ceiling checks, and
the durable endpoints described below expose those checks over CapTP.

**Record views.** Resource scope and grant evaluation read revision-checked
record views, shared with the resident graph and ledger. An unloaded record
produces an explicit read demand. Known absence, malformed rows, and stale rows
are refused separately. `GrantPlan` prepares a mutation the same way for
every source: it produces the affected grant, an optional parent update, and
the proposed event, without publishing anything.
`glowcap.loam.access.records` encodes resources, grants, and change events in
the existing Syrup syntax. Decoding is bounded. Only selected grant scopes
allocate, with at most two exact-sized lists and no retained input bytes
([resource record views](../decisions/adr/ADR-0158-access-resource-record-views.md),
[grant records and plans](../decisions/adr/ADR-0166-access-grant-records-and-plans.md)).

**Owner storage.** `glowcap.loam.access.storage` keeps owner headers, policy
descriptors, allocation counters, and sparse resource and grant directories in
ordinary Loam records
([managed owner storage](../decisions/adr/ADR-0167-managed-owner-storage.md)).

- A bounded read pins model records and resumes directory traversal after a
  storage miss.
- Resource creation and shared grant plans stage metadata and bounded change
  history alongside content, in the caller's transaction.
- Each owner keeps 32 batches of at most 16 effects. Grant, resource, content,
  and independent control changes can share one batch. Separate stamps for
  authority, lifecycle, inventory, placement, subtree, and content tie each
  scoped view to committed batch positions. An unchanged effect adds no
  history.
- Native observation loads bounded replay and returns owned, scoped snapshots
  with opaque cursors bound to their context. Hidden commits leave a cursor
  unchanged. Expired visible history asks the reader to resynchronize.
- Native LMDB tests cover reopen, recovery from a lost acknowledgement after
  both commit and abort, refusal on batch overflow, and collection of expired
  batches. Portable tests cover a 258-resource directory with two cache slots,
  stale completions, malformed paths, allocation failure, and cleanup. Loaded
  grant evaluation uses fixed scratch space and never calls the allocator.

**Durable references.** `storage.Capabilities` restores opaque use and control
references from committed descriptor leases
([durable managed capability bindings](../decisions/adr/ADR-0168-durable-managed-capability-bindings.md)).
Each descriptor keeps its exact owner and grant records, and each live
reference uses Loam retention without pinning the record. Bounded operations
load current authority, expose their read work, and admit only the edits their
role allows: use, delegation, or control. Derivation stages the child grant and
its separate use and control descriptors atomically with content. Native LMDB
tests cover reopening with roles intact, uncertain revocation during cold
reads, and descriptor collection after final release. Portable tests cover
ceilings, allocation failures, quotas, and cleanup.

**Hosted endpoints.** `access.hosting.Service` connects managed preparation to
the existing durable Host attachment
([managed Host turns](../decisions/adr/ADR-0169-managed-host-turns.md)).

- Fixed-resource use endpoints check current authority before calling the
  application, and commit content replacements before replying.
- Each content registration and service decoder receives the application's
  own context, borrowed. A preparation keeps its content descriptor and sharing
  entropy source bound across storage reads; [registration tests](../../test/loam/access/registration_test.zig)
  prove instance isolation, callback routing and teardown lifetime.
- Control endpoints stage permitted lifecycle or policy edits through the
  shared grant rules.
- Ordinary durable publications keep and restore these endpoints.
- Zig receipt callbacks reserve bounded continuations of original source intent
  and exact targets. Confirmed commit activates them; unknown commit preserves
  the reservation. Public completion rechecks source admission. Private
  execution preserves exact completed custody and distinguishes unsent from
  unknown failures. Admitted operations preserve child calls and cold reference
  preparation across Host finish, with independent Session admission. Completed
  or cancelled work and foreign Host leases refuse before child effects.
  C/Rust expose callback reservations, owning pending confirmation,
  public projection and private execution with separate sizing. Linux and
  Chromium consumers cover confirmation, refusal, exact failure text,
  source pause and callback observer retirement.
  The [Rooms effect contract](../rooms/session-effects.md) records typed
  results, atomic acquisition and recursive readers. Linux and Chromium prove
  interruption, settlement refusal and cold replay. Production page journeys exercise the managed owner.
  C/Rust configure the shared continuation count, byte and target allowances
  and the forwarded reply allowance. Invalid forwarding storage refuses before
  opening storage; C-created attachment proofs exercise actual custody limits.
- [Registered content graphs](../loam/c-and-rust.md#registered-content-graphs) prepare cold pages through one lease window.
  Payload updates preserve exact committed fields without restoring targets.
  Written pages can retain selected committed fields alongside newly held
  capabilities, without contacting unrelated upstream targets.
  Pages, events and receipts commit together; receipt replay skips unrelated graph preparation. C/Rust expose exact fields, schema/reference/graph/invocation and row-family sizing, plus working-set/save quotas; calls acquire bounded backing as needed.
- Tests cover held CapTP references across pause, resume, and revoke; stale
  queued and cold activation; role separation; commit gating; and cleanup.
  Native LMDB tests restore endpoints and publications after reopen, and block
  calls through lost acknowledgements after both commit and abort.

**Derivation.** Fixed-resource `derive` adds hidden publication reservations
and keeps eight retry receipts per source endpoint
([durable facet derivation](../decisions/adr/ADR-0170-durable-facet-derivation.md)).
Tests cover narrowing of permissions and delegation, expiry without reissuing,
publication custody, and native recovery from a lost reply after reopen
without duplicate grants.

**Crash proof.** The [managed process proof](../../test/loam_managed_crash.zig)
repeats issuance, control attenuation, revocation, content mutation, reference
removal, resource movement, and leaf deletion, killing the process with
SIGKILL at commit, at installation, and before the reply is delivered. Fresh
processes then fetch the durable names, keep the use and control roles, and
verify the committed events.

**Returned capabilities.** A managed content method can hand over the exact
saved authority in a stored reference field, through a declared disclosure
([explicit disclosure](../decisions/adr/ADR-0172-explicit-disclosure-of-returned-capabilities.md)).
Any capability value the method did not declare fails closed before
settlement, both in process and over a live CapTP session.

- Dependent disclosure keeps both the invoking endpoint and a stored target.
  It admits each target method through the current authority of both
  ([dependent returned capabilities](../decisions/adr/ADR-0173-dependent-returned-capabilities-and-reference-edits.md)).
- Strong reference fields can be replaced or removed inside the content
  transaction, with evidence for aborted writes and LMDB reopen.
- [Typed restoration recipes](../loam/references.md) add bounded attachment
  dependencies and checked foreign sturdyrefs, with exact identity checks
  before any field write. Native compaction and restart tests keep the
  original, use, and control roles. Nine process-kill cases cover installing
  foreign fields.
- Foreign dependent calls use owned Host results, and nested replies go
  through ordinary handoff staging.

**Lifecycle and receipts.**
[Managed lifecycle](../decisions/adr/ADR-0178-managed-lifecycle-and-mutation-receipts.md)
adds persistent child indexes, moves checked for cycles and depth, and stable
leaf deletion.

- Native child cursors filter candidates through admission and refuse stale
  continuations.
- Resource and content effects commit with shared receipts. Mutation windows
  keep eight exact results per endpoint, reject conflicts and expired
  sequences, and check current authority before replay.
- Controls support narrowing, independent revocation, and scoped inspection.
- Issued and narrowed controls have independent durable publications. Names
  commit with their exact endpoint, remain hidden until confirmation and survive
  cold discovery without issuer receipt replay. Revocation still limits every
  restored control; a use publication supplies no management authority.
- `derive-managed` keeps the issuer's control separately, and the recipient's
  use cannot recover it.
- Preparations in the same batch validate the combined owner state, including
  independent control revocation. Exact completion tickets keep pending read
  custody, and prepared structural changes keep their resource bindings
  through close.
- CapTP and LMDB proofs cover lost issuance and attenuation replies, exact
  control recovery, hidden children, and rollback.

**Describing access.** `describe-access()` reports a use endpoint's own and
effective policy, using the same evaluator as protected calls
([scoped access descriptions](../decisions/adr/ADR-0171-scoped-access-descriptions.md)).
An inactive endpoint reports only its status, and no ancestor identity or
owner revision is disclosed. Resident and stored native use APIs share this
contract. Tests cover ancestor restrictions, activity from unrelated owners,
stale queued inspection, exact large bounds, and LMDB recovery and reopen.
`describe-control()` reports current management powers without resource or
ancestor identities.

**Observing access.** `mutate(sequence, "observe")` registers a durable
receiver and a separate canceller over an exact descriptor. Receivers poll or
wait inside existing Attachment preparation. Cancelling closes the retained
context and retires both names atomically, and a retried registration recovers
the same references. Tests cover status-only delivery while inactive, ancestor
revocation, hidden activity, overflow, aborted writes, stale reads, allocation
failure, quotas, and 32 parked receivers within declared budgets. LMDB and
process-loss tests cover cold discovery, exact retry, and cancellation at the
commit and publication boundaries. The [observation guide](../loam/access.md#observing-held-access) covers the methods
and their costs. Rust borrows typed snapshots and cursors; the Rooms client
proves commit wake, inactive disclosure, cancellation and cold replay on both stores.
