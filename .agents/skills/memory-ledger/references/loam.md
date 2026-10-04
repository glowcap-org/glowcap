# Loam memory costs

The [memory ledger](../SKILL.md) owns the naming procedure. Derivations live
at each declaration; this inventory names storage and consumer costs.

## The ledger

- **Loam record staging** — `Record.encodeAlloc` measures before allocation and
  copies payload and typed edges once into the prepared record.
- **Loam record residency** — `Cache.acquire` reserves one bounded read buffer;
  completion and leases retain it until their owner releases it. `Slot` owns
  an exclusive empty/loading/resident state and one checked envelope beside
  resident bytes. The initialized slot array pays this fixed metadata cost;
  borrowing a view allocates nothing and repeats no record validation.
- **Loam sparse directory staging** — `DirectoryEdit.stage` encodes and copies
  each changed page once. Unchanged child mappings propagate their existing
  identity without another proposal; an existing leaf edit stages one page
  with two allocations, pinned by the directory cost test.
- **LMDB read materialization** — `Lmdb.readRecord` copies the requested row into
  that buffer before ending the LMDB read transaction.

- **Loam retained actor call** — `hosting.calls.admit` copies borrowed inputs
  into one fixed-size allocation, capped by attachment bytes and per-ingress
  call/byte allowances. Handler scratch, held-reference lists, and the retained
  reply use that buffer. One Host retain per nested capability occurrence and
  its retain-list entry survive preparation restarts until terminal settlement.
  Argument borrows cannot pin an inbound frame across disk I/O.
  `Call.discloseHeld` scans this arena-bounded inventory once per explicit reply
  declaration. Custody insertion preserves the disclosed suffix in constant
  space; neither operation acquires another retain or allocates another list.
- **Loam managed activation** — `access.hosting.Service.behaviors` uses that
  retained arena for preparation state and application scratch. Its opaque
  managed operation allocates through Capabilities' allocator and quotas;
  `docs/loam.md` owns the storage operation and shared-cache budgets. Preparation
  restarts reclaim arena space after retiring reads. The portrait lease survives
  through preparation deinit at settlement, including commit and reply retries.
  `ContentCall.appendReference` charges its replacement spine to that arena,
  bounded by the content schema's edge capacity before capture.
- **Loam content registration binding** — `working.BoundContent` holds one
  descriptor by value in the existing retained call arena. Its borrowed context
  and callbacks serve admission, references and invocation without reselection.
  `sharing.Sharing.entropy_source` retains the entropy callback/context pair
  across preparation reads. Both charge existing call bytes, with no new heap
  allocation or application-state copy.
- **Loam access snapshot projection** — `description.encode` projects bounded
  policy keys and exact unsigned values into the retained call arena. Only
  inspection calls allocate their snapshot storage. The
  maximum-metadata description test covers all 64 permissions and 16 bounds
  across ceiling, configured, and effective policies within the default arena.
- **Loam policy dependencies** — `Policy.prerequisite_masks` adds 512 inline
  bytes per copied descriptor. `Policy.init` compiles borrowed key pairs without
  allocation; `OwnerRecord` persists eight bytes per declared key in one bounded
  list. Validation visits at most 64 selected permissions. The maximum-descriptor
  round trip proves the existing 4 KiB owner payload budget still holds.
- **Loam actor settlement preparation** — `hosting.calls.settle` uses a temporary
  arena for model/value lowering into existing Vat/Host resolver ownership.
  Allocation failure keeps the operation available for retry, without invoking
  the behavior again. Core leases, staged records, Host queues, and backend
  mapped pages retain their separate bounds.
- **Owned Host call result** — `callCapability` allocates one operation and an
  exactly sized reply buffer, plus temporary lowering scratch. `ownValue`
  copies callback-borrowed bytes/spines and retains each capability occurrence;
  cancellation and terminal release reuse existing vow/value owners. Local
  deferred resolver replies retire unshared temporary export projections.
- **Loam reference preparation** — `references.Set` slots, saved recipe copies
  and forwarded reply buffers use the retained call arena. `reference_save.begin` owns one
  capability retain, bounded recipe bytes and any Host enlivenment; attachment
  save quotas and Host network budgets both apply. Scope registration uses one
  fixed owner array. Each recipe replacement creates one bounded record until
  tracing reclaims its retired dependency; envelope encoding adds one byte per
  edge for restoration kind.
  `Set.create` retains every declared save target before preparation can wait;
  starting each Save transfers that custody, and reset releases unstarted targets.
- **Loam derivation intent** — `DerivationRecord.encodeIntent` copies decoded
  grant terms into canonical retained-call bytes for durable retry comparison.
  Receipt staging owns its separate record copy; no borrowed wire bytes survive.
- **Hidden durable publication** — `reserveDurableCapability` reserves the owned
  name, registry capacity, actor root, and pending-work custody before storage
  submission. Confirmation allocates nothing; cancellation releases custody.
- **Cold publication discovery** — `Discovery.create` allocates its owner and
  fixed arrays for `max_names` groups and `max_fetches` waiters (defaults 16/64).
  Admission retains one 16-byte name per group and no inbound frame bytes.
  Groups keep a Host work lease until submitted lookup/read completion, even
  after all fetches cancel. Descriptors use the existing Store cache; successful
  replies use ordinary endpoint/projection custody and create no registry row.
  Persistent name reservations retain 25 key bytes plus 33 identity bytes before
  backend overhead, including after collection. `Host` adds one opt-in provider
  pointer; the single engine resolver callback replaces the old callback.
- **Loam committed residency** — `Store.retainOnCommit` transfers prepared
  record buffers to eligible cache slots during installation, without another
  allocation or copy. Admission establishes the checked envelope once; views
  reuse it. Pinned snapshots cannot be displaced; a full cache leaves
  the buffer with its transaction owner for release.
- **Loam collection custody** — `Store.captureCollectionCustody` creates one
  bounded `Custody` journal and record-sized worker scratch per cycle. Root
  capacity grows only within `max_collection_roots`; new custody reserves before
  publication. A resident portrait reports its strong edges once per cycle;
  its marker fits the existing slot. `Store.prepareCollection` borrows pending
  obligations and reuses scratch. Backend tracing copies the current row there
  before writes invalidate mapped borrows. Allocations survive batch abort and
  commit-outcome recovery, and are freed at completed idle or Store teardown.
  `Store.retain` uses the fixed registry allocated at Store initialization;
  marks and pending trace entries occupy backend storage, not actor residency.
  Confirmed collection receipts alone acknowledge submitted roots. The
  collection-cost smoke profile holds one submission per unchanged root and
  one scratch allocation per cycle.

- **Loam C registration inventory** — `Content.init` copies bounded method
  tables and names; `Attachment.create` owns behavior arrays and the fixed
  `cache_slots + 1` Work pool until successful detach.
- **Loam C callback projection** — `input` projects C argument spines and
  `requirementWith` copies bounded keys/facts into the existing retained call arena.
  Leaves borrow the retained invocation. `reply` and `replace` copy foreign
  output into that arena before callback return.
- **Loam C reference declarations** — `reference_callbacks.save` copies bounded
  request spines and foreign URI bytes into the retained call arena. Restoration
  uses the same spine; Host retains and save quotas belong to shared preparation.
- **Loam Rust consumer boundary** — `invocation` in the Rust Loam content
  projection copies arguments into the existing owned String/Vec representation;
  reply `SendArena` lives through the C copying call. `work::execute` allocates
  one Tokio job and shared retirement cell per LMDB effect, borrowing its
  payload. Rust callback contexts occupy one fixed Vec for the attachment.
  `PolicyValue.derivation_arguments` constructs bounded owned wire arguments
  in their final spine; policy edits use the same builder without a temporary
  policy Vec or growth reallocation. Nested management selections own their
  required argument lists for the Session future.
  `content::Callback` shares the existing Context and holds the Host diagnostic
  id in each fixed registration. Caught panics materialize failure detail only
  on refusal and use the Context's bounded journal; ordinary calls allocate
  no diagnostic state, and deliberate refusals do not enter that journal.
- **Browser Loam transaction snapshots** — the Rust browser Plan owns at most
  1,024 loaded rows and 1,024 tentative writes under the combined resident and
  staging byte allowance. Reads copy once into Rust; writes copy into the
  overlay and JavaScript. Re-evaluation drops tentative writes. Its declaration
  owns these async lifetime costs; storage statistics count all adapter copies,
  including retries. One retained task and callback survives observer abandonment
  until physical IndexedDB retirement. C execution keeps POD plans in the fixed
  Work inventory and introduces no per-plan heap allocation.
