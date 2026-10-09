# Loam memory costs

The [memory ledger](../SKILL.md) owns the naming procedure. Derivations live
at each declaration; this inventory names storage and consumer costs.

## The ledger

- **Managed event history reservation** — `History::bytes` charges direct edit
  archive coordinates before line commitment. File actors share the same event;
  commit fills one bounded identity slot without copying event or attachment
  backing. Native and browser projections disclose it through the original source.
- **Managed recording admission** — `Recording::record` retains one archive
  completion task per admitted record under `MAX_PENDING`. `CallbackFile`
  retains the original inbox authority and one lazy reader. `File::mediated`
  charges its boxed body and explicitly supplied backing through
  `File::retained_heap_bytes` and the archive's `input_budget`.
- **Shared archived attachment custody** — `Work::spawn_reader` charges one
  Rc body, actor closure and exact local reader metadata through the archive
  hosting budget. Deferred selection and byte reads retain the existing queue
  permit; source selection, recursive scope and revocation survive every wait.
  `Budget::mint_local` bounds cumulative facet and reader issuance separately.

- **Loam record staging** — `Record.encodeAlloc` measures before allocation and
  copies payload and typed edges once into the prepared record.
- **Loam record residency** — `Cache.acquire` reserves one bounded read buffer;
  completion and leases retain it until their owner releases it. `Slot` owns
  an exclusive empty/loading/resident state and one checked envelope beside
  resident bytes. The initialized slot array pays this fixed metadata cost;
  borrowing a view allocates nothing and repeats no record validation.
- **Runtime observation reclamation** — `Registration.initLifetime` retains
  one optional `ObservationCancellation` while replacing an expired context.
  Hosting registration keeps one marker lease and two publication leases in
  its fixed preparation state. Reclamation visits the bounded observation
  index and stages at most one cancellation with the replacement, rather than
  allocating an inventory or staging a transaction proportional to abandoned
  registrations. General durable registration adds no lifetime scan.
- **Loam sparse directory staging** — `DirectoryEdit.stage` encodes and copies
  each changed page once. Unchanged child mappings propagate their existing
  identity without another proposal; an existing leaf edit stages one page
  with two allocations, pinned by the directory cost test.
- **LMDB read materialization** — `Lmdb.readRecord` copies the requested row into
  that buffer before ending the LMDB read transaction.

- **Loam retained actor call** — `Memory.init` binds immutable-input and
  restartable-working block chains to one physical allowance at the stable
  operation address. Blocks use standard fixed-buffer allocation; headers,
  alignment and spare capacity remain charged until chain retirement.
  The fixed Memory state occupies its operation slot; incremental block
  acquisition adds allocator events on growth rather than an eager full buffer.
  `hosting.calls.admit` reserves the complete ceiling under attachment and
  ingress limits, copying borrowed inputs once. Handler scratch and held lists
  use working blocks. `Call` names this single memory owner. `Call.work` borrows
  its enclosing operation's stable Host lease in one inline pointer; child calls
  and cold reference preparation reuse existing Host/Vat completion owners.
  Near calls charge
  copied inputs and working storage to the same configured ceiling, using the
  turn arena as their backing owner; their composite replies copy into the turn
  before call retirement. That turn may retain its slabs until turn completion.
  Retained replies borrow their owner without another copy;
  C output and local forwarded replies copy at their callback boundaries.
  One Host retain per nested capability occurrence and
  its retain-list entry survive preparation restarts until terminal settlement.
  Argument borrows cannot pin an inbound frame across disk I/O.
  `values.allocationBound` and `calls.inputAllocationBound` derive typed spines,
  aggregate leaf copies and contiguous argument retain custody. `Call.heldAllocationBound`
  charges every acquisition occurrence and fresh list-growth spine.
  `Call.discloseHeld` checks freshly adopted custody at the undisclosed boundary
  in constant time; other declarations scan the arena-bounded inventory.
  Custody insertion preserves the disclosed suffix in constant
  space; neither operation acquires another retain or allocates another list.
- **Loam managed activation** — `access.hosting.Service.behaviors` uses that
  retained arena for preparation state and application scratch. Its opaque
  managed operation allocates through Capabilities' allocator and quotas;
  `Read.GrantCache` reuses selection scratch for one decoded committed grant
  whose scopes both use inline coordinates. The portrait owns scalar fields
  and its label; exact object/revision identity gates reuse. Selected scopes
  and proposed grants decode afresh. `Read.grantScratch` invalidates the
  portrait before grant or inventory decoding borrows those bytes. No
  additional buffer allocation or record lease exists.
  `docs/loam/store.md` owns the storage operation and shared-cache budgets. Preparation
  restarts reclaim arena space after retiring reads. The portrait lease survives
  through preparation deinit at settlement, including commit and reply retries.
  `ContentCall.appendReference` charges its replacement spine to that arena,
  bounded by the content schema's edge capacity before capture.
  Committed receipt replay checks current admission and receipt result custody,
  skipping graph snapshots, foreign restorations and new save declarations.
  `working.invocationAllocationBound` composes private State and Mutation costs;
  receipt codecs derive byte bounds from their shared scalar writers. The C
  projection adds borrowed argument spines, policy copies and one owned reply
  conversion. Reply topology covers persisted results, including repeated
  capability occurrences even when the receipt stores one distinct edge.
  Resolver settlement uses separate temporary arenas; these are outside retained
  call backing, like Capabilities operations and encoded Store staging.
  `ContentCall.retainPreparedReference` validates existing prepared custody and
  acquires one Host retain without a second buffer or retain inventory. The C
  result transfers that occurrence; the Rust wrapper adds its existing release
  cell and one shared finalizer guard, owned until the last clone retires.
- **Loam content registration binding** — `working.BoundContent` holds one
  descriptor by value in the existing retained call arena. Its borrowed context
  and callbacks serve admission, references and invocation without reselection.
  `sharing.Sharing.entropy_source` retains the entropy callback/context pair
  across preparation reads. Both charge existing call bytes, with no new heap
  allocation or application-state copy.
  `control_request.Request.attenuate` retains its captured entropy source,
  proposed publication secret and Host reservation in the same call arena.
  `Graph.Spec.requirement_verbs` declares which original source methods need
  current graph pages during forwarding admission. `working.State.prepareGraph`
  uses the existing graph allowance and restores no capability fields for that
  check. Unlisted source methods retain root-only admission. The C registration
  owns one copied verb spine and at most 128 bounded method-name copies through
  `graph_callbacks.copySpec/freeSpec`; Rust's registration owns the input strings
  and one transient POD spine per declared graph. These are attachment costs,
  independent of retained-call graph and reference preparation.
  `sharing.Sharing.control_publication_prepared` records exact publication
  discovery after retaining its fixed secret and releasing the temporary row,
  before the control window opens. Issued and narrowed controls add one graph
  recipe, with no grant inventory restoration or added resident allowance.
  Reservations activate only after confirmed commit.
- **Loam content page snapshot** — `content_graph.Prepared.advanceCopying`
  copies validated child payloads and edge bytes into the retained call arena,
  releasing each page lease before loading the next. Registered aggregate
  payload/edge limits admit each copy; the canonical root closure retains the
  graph through outcome. Root-link decoding is linear across cold waits.
  `ContentCall.replaceGraph` validates the full candidate before capturing held
  fields, then copies candidate spines into that same call owner.
  `graph.allocationBound`, service and working contributions derive snapshot,
  candidate, view and staged-edge demand at each owner. `includeTotal` charges
  aggregate bytes once, with placement padding per possible positive request.
- **Loam access snapshot projection** — `description.encode` projects bounded
  policy keys and exact unsigned values into the retained call arena. Only
  inspection calls allocate their snapshot storage. The
  maximum-metadata description test covers all 64 permissions and 16 bounds
  across ceiling, configured, and effective policies within the default arena.
- **Loam branch inventory projection** — `inventory.Page` owns at most 32
  descriptive rows in the retained call arena. `inventory.rowSizeBound` admits
  the 64 KiB encoded page allowance before projection. Labels and policy spines
  copy once because decoded source rows release before reply. `GrantInventory`
  reuses the operation's grant decoder scratch and the existing four-level
  directory cursor; it retains one child lease and no population mirror.
- **Loam held-control inspection** — `Inspection.prepare` copies one grant's
  inline label and policies out of the operation decoder into the retained
  call arena. `inventory.encode` projects that fixed snapshot with its existing
  row renderer. Inspection holds no use capability or additional record lease.
  `Operation.inspectFixedAccess` copies scalar policy snapshots through the
  existing `description.encode` renderer; it reuses model reads and restores
  no use endpoint. Only exact-resource ceilings have a single effective view.
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
- **Loam continuation custody** — `Continuation.reserveCopying` independently
  bounds one State and its immutable intent/target/retain storage. Confirmation
  transfers that reservation without allocating; absence releases it and unknown
  commit keeps it held. `Continuation.sizeBound` derives physical backing from
  argument topology, verb bytes and target occurrences. No Store lease survives
  a target wait. One word in State counts read-scope retains and one word in Attachment
  counts continuations with effect custody. Passive readers can survive close
  as unavailable routing without a reference scan or a duplicate intent copy.
  Public projection owns one endpoint box and registry retain.
  Private execution owns a temporary endpoint plus one 32-byte Dispatch on
  64-bit, shared by observer, endpoint and admitted operation. Constructor
  refusal and cancellation proofs pin retirement. The Dispatch records only
  target admission; it never copies a result or records an effect receipt.
  The C/Rust Limits projection holds four scalar continuation/forwarding
  allowances, adding 32 inline bytes per stored Limits on 64-bit and 16 on
  Wasm32. `Store.hostingOptions` owns validation and attachment configuration;
  there is no additional allocation, invocation copy or graph traversal.
- **Loam continuation binding owners** — `continuations.Control` allocates one
  40-byte observer on 64-bit before reservation. Kernel confirmation and the
  caller share it; confirmation transfers custody without allocation or foreign
  callbacks. Canceled metadata is caller-owned outside active kernel limits.
  `effect_execution.Observer` allocates 80 bytes on 64-bit beside the original
  owning Call and its reply backing. Its projection Memory owns only bounded C
  child spines; byte leaves borrow the result and each observation grants its
  own capability retains. `Observer.projectionBytes` derives physical backing
  from the reply allowance, including block headers and growth slack.
  Temporary C target and constructor argument spines belong to the callback
  arena and constructor arena respectively; admitted input copies once through
  the existing queue. Size queries separate every owner, and C refusal tests
  pin metadata, observed demand and balanced cleanup.
  Rust handles clone the existing AttachmentInner Rc; callback contexts retain
  Weak owners. Getter references and ready Arguments use ordinary independent
  guards and String/Vec copies. Callback-refused execution Drop parks its actual
  handle and Rc in the existing finalizer queue. The driver already retires
  callbacks at its step boundary; byte-fed action and persistence boundaries
  drain outside callbacks, including before propagating failure.
- **Loam forwarded result custody** — `Forwarding.begin` owns a bounded Host
  Call in immutable input storage so source rechecks retire preparation without
  losing the result. Inner target and outer executor reply buffers have separate
  limits and lifetimes; settlement copies exact result custody into the outer
  owner before retiring the inner one. Protected delivery prepares current source
  admission again; private settlement preserves completed custody after source
  loss. Preparation resets never repeat target dispatch. Host/Vat rows and
  temporary endpoint costs remain outside retained Loam call backing.
  Fixed-capacity or retired-capability refusal rejects the immutable reply;
  rejection heap refusal preserves its owners for retry without redispatch.
- **Loam recursive read custody** — `ReadScope.createCopying` copies source
  intent, method names and result-role arrays into one bounded Memory. Its
  fixed scope and weak target/interface cache share continuation count and
  byte allowances. `ReadScope.sizeBound` owns their physical derivation;
  passive scopes retain closed attachment metadata through final release;
  outstanding calls still block close through the existing pending-call budget.
  a traffic witness refuses in-place resizing and checks every shared allocation.
  Facades own separate Host/Vat boxes and registry retains, with synchronous
  constructor refusal. In-flight Projection metadata retains the existing
  scope, adding no declaration copy. `ReadScope.transform` copies only reply
  container spines into Call backing; scalar leaves borrow forwarded custody,
  and each replacement occurrence enters the existing held/disclosed inventory.
  The C callback projects interface/method POD spines into that call arena,
  borrowing names and role arrays until the shared copy. Rust owns two temporary
  flattened method and interface Vec spines for each synchronous declaration.
  `ReadScope.createRetaining` reuses an activated continuation's immutable
  intent, source and argument custody without cloning them or retaining each
  occurrence again. The bounded scope copies only its interface declaration
  and weak cache, then holds one continuation reference through final reader
  retirement. Its full physical allowance remains bounded by `sizeBound`.
  C continuation projection uses a transient Memory capped by the same owner
  ceiling for its POD spines; these retire before the facade returns. Host
  endpoint storage remains independently owned and bounded. The continuation
  proof checks input aliasing, source retains and every constructor refusal.
  Resolver retry reuses the immutable upstream result and the scope's weak
  identity cache, with no second dispatch or retained reply tree.
  Rooms typing uses this same scope: `presence::invoke` owns three bounded
  source arguments, one method declaration and exact source/target custody.
  `RoomsManagedTyping` charges its opaque wrapper through `Driver::hold`;
  release retires the typed sender and its shared facade.
  Rooms bridge-form readers reuse the same scope with one exact seat coordinate
  and one read method. `reads::invoke` retains the original source and seat;
  the browser reader charges its coordinate input through `Driver::submit`.
- **Rooms receipt execution** — each of the at most eight managed session jobs
  owns its original intent and one execution phase. Capability-result acquisition
  adds one Rc with bounded data/URI and one boxed lookup future; plain results
  skip that phase. Settlement retains one boxed future and its bounded argument
  copy, writer lock and reply receiver across observation timeout or task
  interruption. Terminal failure retires that attempt while retaining the exact
  outcome. Direct idempotent settlement uses the application receipt and adds
  no second shared mutation receipt. The embedding supplies the owning reply
  allowance; `EffectExecution::result_size_bound` names its shared/C custody.
  Production read forwarding derives complete history/archive/blob shapes in
  `profile::reader_reply_bounds` through shared value and forwarding sizing; result buffers
  exist only during admitted calls, independently of persistent graph residency.
  `profile::reader_limits` composes the Host Call's two allocations and physical
  arena allowance into whole-call reservations as well as reply capacity.
  Forwarding allocates inside that call, without a private execution observer
  or C result projection. `Call.allocationBound` owns its private state layout.
  `realization::Source` retains one initiating endpoint and bounded scalar target
  selection. Each typed operation copies that selection and owns one retained
  Command. Acquisition uses one bounded workspace snapshot/candidate and at most
  three result/release coordinates; no raw upstream actor is restored for it.
  `results::creation::Acquisition` retains two temporary capabilities, one
  bootstrap outcome and two successful Ref slots inside that same bounded job.
  Successful outcomes own two URIs capped by `ReferenceRequest::MAX_URI_BYTES`;
  retries copy their bounded text into the two-field settlement spine. Terminal
  bootstrap errors stay cached; no second issuance observation is allocated.
  The whole boxed lookup future preserves its pending Host work across deadlines.
- **Rooms upload custody** — `uploads::Pipeline` holds one private execution
  independently of its polling task. Each job owns at most eight upload entries,
  one retained completion future and one bounded chunk before write admission.
  `UploadProgress` owns offsets and acknowledgments. Source reads and append
  observations stay inside the same future across interruption; no file assembly
  or second scheduling queue is retained. Input parsing bounds the seven-field
  attachment suffix before allocating its temporary view spine.
- **Rooms sender leases** — `sources::Blob::lease` increments an inline pool
  counter and retains the existing slot without allocating. `Sources::lend`
  owns at most eight leases and an exactly reserved exported-root spine through
  settlement. Each source actor holds one additional inline lease until its
  exact receiver roots retire. Prepared uploads hand lifetime to those roots
  when delivery can start; releasing the request observer cannot expire them.
  Roots use ordinary Host actor custody. Explicit expiry and
  consumed coverage retire backing even under a lease; in-flight reads alone
  keep expired backing charged. Pressure eviction skips both leases and reads.
  `Sources::lend_local` uses that same population and Host spawn transaction,
  without publishing an alias or creating a session. `LentSources::retained_bytes`
  charges the lease/root vector capacities; `Command::retained_bytes` adds them
  to its retained envelope. The pool independently charges declared source bytes
  and in-flight reads, including asynchronous local callbacks.
- **Rooms effect dispatch preparation** — `session::dispatch::Dispatch::parse`
  copies admitted command arguments into a bounded Rust grammar spine, then
  owns the selected workspace ID and outgoing mutation. Request count/byte
  admission bounds these temporary copies. Selection retires before worker
  installation; the existing receipt and continuation retain the actual typed
  targets. Preview validation owns bounded temporary URL strings and one encoded
  selection in the outgoing mutation; it adds no retained worker state.
  Subscription adds one inline inbox coordinate, two-element coordinate,
  original-target and runtime-target spines, and one owned outgoing callback
  occurrence. Its dependent
  callback uses the existing facet actor and two retains; those live with the
  worker and upstream holder. Membership normalization owns at most three
  temporary coordinate/field spines and one bounded result serialization through
  settlement, using ordinary live-save admission for each returned facet.
  Moderation, revocation and policy changes add no authority table or
  worker phase. `Dispatch::bind` captures one bounded room name for a policy
  change; `Prepared::read` owns one bounded typed name/policy serialization for
  settlement, which retires with the existing job.
  Membership retirement adds one inline expected seat key in its temporary
  selection. `departure::retire_membership` moves each removed topic/line list
  out of the admitted candidate and borrows its coordinates through release;
  it allocates no inverse index or duplicate inventory. The existing continuation
  and receipt retain the old exact seat. Its combined workspace/receipt update
  uses the same full graph encoding and staging costs as local departure.
- **Rooms local command staging** — `local::apply` borrows admitted request
  strings through one spine bounded by the command argument count. Changed
  fields, ignored-name folding and bounded JSON lists belong to the decoded
  candidate. `content::commands::admit` copies canonical intent into its receipt,
  saves the exact source and stages the full codec graph with retained custody
  edges. Commands use that application receipt directly; preparation performs
  no shared sequence query or second mutation-receipt allocation.
  Graph encoding owns the payload/page copies. A local command creates
  no worker, continuation, target restoration or result-acquisition phase.
  `departure::apply` moves removed intent rows out of their existing lists and
  borrows their scalar coordinates. `Intent::coordinates` owns the shared,
  allocation-free walk for validation and alias checks. Retirement checks the
  bounded remaining intent once per removed selection; it keeps no inverse
  authority index. Fallback selection copies only the chosen bounded ID.
  `selection::apply` decodes scalar room/archive keys and one bounded operator
  list into the candidate. Operator replacement moves the old list and borrows
  its coordinates for the same alias-aware retirement. These selections copy
  no actual capability and perform no restoration or worker allocation.
- **Rooms receipt result import** — `content::imports::references` restores only
  the original source, selected result and an occupied destination. Its request
  keys are scalar; canonical-intent validation owns one bounded text copy.
  `imports::invoke` compares actual references before reusing a saved strong edge
  in the ordinary decoded custody candidate. Existing graph encoding owns the
  payload and descriptor copies. The transfer retains no new worker, wrapper,
  result inventory or Save declaration; its idempotent writer observation uses
  the existing serial Host call owner.
- **Rooms custody acquisition** — `content::acquisition::Request::read` keeps
  single ingress inline and bounds bulk entry and release spines to one custody
  page each. Entries borrow references and URI text from retained input; only
  decoded intent owns a candidate. `acquisition::references` owns at most two
  declarations per import, restoring occupied destinations only. SaveLive and
  Save retain through the shared preparation owner. Release performs no upstream
  restoration. One graph replacement stages the candidate; exact retries stage
  nothing. `Import::into_fields` moves capability/URI ownership into the existing
  writer call and allocates one coordinate serialization, with no scalar Vec.
  `Session::acquire_operations` prepares the bounded boot inventory before
  fetching. Its URI strings move into Imports, temporary reference custody dies
  on refusal, and the selection candidate commits with acquisition and retirement.
- **Rooms prepared management** — `client::access::Mutation` owns its exact
  control guard, caller and argument vector through resubmission. Policy and
  label encoding use the existing binding declaration owners; lifecycle owns
  three arguments, one bounded verb and eight revision bytes. `retained_bytes`
  charges complete vector and leaf capacities. Browser `RoomsManagedEdit`
  holds this request under Driver's aggregate byte and handle allowances;
  preparation retires its label/input temporary before submission. Host call
  lowering retains its existing named costs. No second receipt or task registry
  is introduced.
- **Rooms shared observation** — `ObservationRequest::new` owns two Arguments
  and seven verb bytes in its fixed three-slot spine for durable registration
  replay. `ObservationRequest::new_live` owns a twelve-byte verb and sixteen
  request identity bytes in that same spine, avoiding accidental shared
  cancellation custody when callers discover the same mutation sequence.
  Only a proved sequence collision allows resequencing; pending and unknown
  outcomes retain the original request. `Observation::poll` and
  `receive` copy one 56-byte cursor into temporary outgoing storage that retires
  at vow admission, before awaiting. `ObservationState` owns the ordinary reply
  once; `ObservationDescription::read` borrows its cursor, policies and flags
  without another allocation. Restored receiver/cancellation custody transfers
  through `Observation::new` without a registry, timer or registration mutation.
- **Rooms manager queue scope** — `authority::revocation` owns one bounded room
  name and the original generation beside its existing token copies until the
  writer prepares the change. `prepare_link` likewise captures the original
  generation inline. `Links::resolve_for` uses two temporary folded names to
  compare room identity; all copies retire with preparation. The existing
  bounded writer owns these jobs; no additional registry or queue is created.
- **Owned Host call result** — `callCapability` allocates one operation and an
  exactly sized reply buffer, plus temporary lowering scratch. `ownValue`
  copies callback-borrowed bytes/spines and retains each capability occurrence;
  cancellation and terminal release reuse existing vow/value owners. Owning
  local calls use the same result owner and existing charged Vat queue, with
  separate producer, row and input custody listed in the Actor ledger. Local
  deferred resolver replies prepare owned Values directly without temporary
  Session export projections.
  Pending call and enliven observations retain their exact installed Listener
  across independently compiled native archives. The POD listener fits beneath
  their existing inline failure arm; producer cancellation fits beneath its
  existing fallible cancellation arm. Compile-time checks hold those bounds,
  with no new allocation or operation footprint.
- **Loam reference preparation** — `references.Set` slots, saved recipe proofs
  and forwarded reply buffers use the retained call arena. Two bounded slot-index
  arrays borrow the exact views and capability identities; they add no retains.
  Explicit `restore_record.retain_uri` requests copy only their foreign recipe
  bytes through callback return. `references.retainedUriAllocationBound` derives
  their extra demand; ordinary restoration retains no URI copy or row lease.
  Metadata-only inspection uses the same exact selection, bounded URI copy and
  one recipe window. It never restores or discloses a capability; revoked
  exporters require no connection, local scope or live endpoint to inspect.
  Restoration sorts once at declaration, while capture sorts on its first use
  after preparation advances. Lookup preserves declaration order and live-first
  custody without walking the full population for every field.
  URI parse components
  and save-admission retain spines use a temporary block chain charged to the
  same call quota. They retire after synchronous Host admission, before a
  pending result or the next field; Host owns any parked locator and Swiss bytes.
  Canonical save URIs use one measured allocation and bounded shared writer.
  `references.allocationBound` composes private preparation and save costs with
  one URI parse window. `AllocationBound.physicalBytes` includes block headers,
  placement padding and growth slack. C/Rust reference sizing also includes
  every fresh C declaration-spine growth and one supplied URI copy per save.
  Invocation projections, snapshots, candidates, held fields, application
  callbacks and replies remain separately owned demand. The foreign benchmark
  adds its fixed callback calibration to this bound; its larger admission
  ceiling allocates no eager buffer. On the aarch64 smoke workload, independent
  scratch adds 24 allocations per 17 foreign calls while the smaller Call owner
  reduces live Zig heap by 1152 bytes across eight source and 64 target slots.
  `reference_save.begin` owns one
  capability retain, bounded recipe bytes and any Host enlivenment; attachment
  save quotas and Host network budgets both apply. Scope registration uses one
  fixed owner array. C declarations bound old restores and new saves together
  by twice the field budget; `Attachment.create` projects the configured live
  Save ceiling. `Set.captured` borrows one proof from each call-owned Save;
  restored fields reuse a matching retained committed edge. `Saved.stage` creates
  one immutable recipe row per proof and transaction ticket. `copySaved` copies
  bytes and retains authority only for an independently owned Save that may
  retire before the call. The staging cache stores a ticket and edge per proof,
  with one pointer per preparation slot; abort retries consume fresh IDs.
  Envelope encoding adds one byte per edge for restoration kind.
  `Set.create` retains every declared save target before preparation can wait;
  starting each Save transfers that custody, and reset releases unstarted targets.
  Completed recipe restoration releases its lease before preparing another
  field; retention and exact held capability custody survive through settlement.
  The ordinary single-view inventory stays inline; graph inventories borrow
  prepared snapshots and charge their view spine to the retained call arena.
- **Loam live custody** — `LiveScope.init` allocates one fixed reservation array
  and reserves its complete recipe index before startup. One exact Host retain
  transfers from reservation to committed custody without allocation. Entries
  do not root recipes; one runtime slot per step checks collection through the
  existing read lane. Startup and pending cleanup carry their scalar state in
  the same scope. Call-owned live declarations, epoch snapshots and proofs use
  the existing Set/Slot/SavedState allowance. C activation allocates one Scope
  beside its attachment and adds one pointer to that owner. Rust marker metadata
  is a 33-byte value; activation wakes the existing Host drain and adds no
  capability map, worker lane or authority copy.
  `Scope.reserveDependent` constructs the existing dependent actor with its
  two authority retains, borrowing their capability names in an optional pair
  in each fixed reservation. One temporary canonical target spine and the
  ordinary reservation spine use the call arena; reference sizing includes
  both. Pair matching scans the bounded inventory and constructs no facet.
  Rust `Call.prepared_live_dependent` materializes one ordinary Ref occurrence
  and release-status cell; the shared reservation owns its retain.
- **Loam derivation intent** — `DerivationRecord.encodeIntent` copies decoded
  grant terms into canonical retained-call bytes for durable retry comparison.
  Receipt staging owns its separate record copy; no borrowed wire bytes survive.
- **Hidden durable publication** — `reserveDurableCapability` reserves the owned
  name, registry capacity, actor root, and pending-work custody before storage
  submission. Confirmation allocates nothing; cancellation releases custody.
- **Cold publication discovery** — `Discovery.create` allocates its owner and
  fixed arrays for `max_names` groups and `max_fetches` waiters (defaults 16/64).
  Waiter backing is `max_fetches * @sizeOf(?Waiter)`; its fetch destination
  tags an exact wire answer or a local recipient and Host work lease. Own-key
  enlivenment reuses this array and the name groups. It adds no lookup map,
  session, route copy or operation allocation; the existing observation holds
  one scalar lookup ID. A hot local result retains the exact rooted actor
  without projection. Each cold local waiter owns one work lease through
  settlement, exact cancellation or Host shutdown.
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
  tables, names and optional graph schema identifiers; `Attachment.create`
  owns behavior arrays and the fixed
  `cache_slots + 1` Work pool until successful detach.
- **Loam C callback projection** — `input` projects C argument spines and
  `requirementWith` copies bounded keys/facts into the existing retained call arena.
  Leaves borrow the retained invocation. `reply` and `replace` copy foreign
  output into that arena before callback return.
- **Loam C reference declarations** — `reference_callbacks.save` copies bounded
  request spines and foreign URI bytes into the retained call arena. Restoration
  uses the same spine; Host retains and save quotas belong to shared preparation.
- **Loam C graph projection** — `graph_callbacks.project` allocates POD page
  descriptors in the retained call arena, borrowing snapshot payloads.
  `graph_callbacks.replaceCopying` validates foreign candidate shapes, then
  copies payloads and typed field spines before callback buffers retire.
  C/Rust graph sizing composes those copies and the three possible prepared
  requirement/reference/invocation page projections
  with the shared graph contribution; other call owners remain separate.
  `Call.replace_graph` in Rust owns temporary ABI descriptor/field spines only
  through that copying setter; Zig owns selection, capture and transaction state.
  `Call.page_reference` materializes one Rust Ref occurrence and its existing
  release-status cell. The retained shared call owns the capability custody;
  no separate Rust Host guard is acquired for this borrow.
- **Loam Rust consumer boundary** — `invocation` in the Rust Loam content
  projection copies arguments into the existing owned String/Vec representation;
  reply `SendArena` lives through the C copying call. `work::execute` allocates
  one Tokio job and shared retirement cell per LMDB effect, borrowing its
  payload. Rust callback contexts occupy one fixed Vec for the attachment.
  Browser `work::Custody` charges one inline physical-job counter at
  `AttachmentInner`, bounded by the C work-slot inventory. Close joins those
  jobs even when their progress observer was cancelled; the existing progress
  notification wakes the barrier without another task or payload copy.
  `registration::Prepared` owns temporary method, graph and C declaration
  inventories through attach; only its fixed callback Vec survives attachment.
  `PolicyValue.derivation_arguments` constructs bounded owned wire arguments
  in their final spine; policy edits use the same builder without a temporary
  policy Vec or growth reallocation. `IssuePolicy.issue_arguments` reserves one
  twelve-field spine for immutable ceiling and initial configured policy;
  both policy triples survive exact replay. Nested management selections own their
  required argument lists for the Session future.
  `content::Callback` shares the existing Context and holds the Host diagnostic
  id in each fixed registration. Caught panics materialize failure detail only
  on refusal and use the Context's bounded journal; ordinary calls allocate
  no diagnostic state, and deliberate refusals do not enter that journal.
The [Rooms session inventory](rooms.md) owns managed commands, callbacks,
supervision, activity and browser handle costs.

- **Loam prepared creation binding** — `StagedResource` retains one existing
  Store Rc and fixed resource metadata through embedding persistence. The
  core owns staging; submission transfers outcome recovery to Store. There
  is no new heap allocation or graph copy for this guard.
- **Rooms private bootstrap metadata** — `Bootstrap::open` retains fixed
  identity and anchor values through the existing creation and attachment lanes.
  Process `storage::session::Prepared` borrows its fixed encoded bytes through
  atomic replacement. Browser `storage::session::row` copies those bytes into
  one bounded Uint8Array for the existing IndexedDB transaction owner. Tab keys
  contain at most 64 ASCII bytes; persistence owns one key copy per metadata
  future. No grant population or independent scheduler is retained.
- **Browser Loam transaction inputs** — `browser::plan::Plan` owns metadata,
  one supplied row and one missing key. Its constructor derives the allowance
  from fixed Plan state, metadata size, `record_bytes` and physical key bounds.
  A supplied row copies once into Rust; a write copies once into JavaScript
  before IndexedDB synchronously serializes it. No Rust overlay is retained.
  Statistics count adapter copies, emitted writes and cumulative submitted
  write bytes; they exclude IndexedDB's queued values and database cache.
  JavaScript retains one pending read request and clears its callback before
  resumption. Each transaction owns one fixed Rc refusal slot until its terminal
  event, preserving the original Rust error and its causes through JavaScript's
  abort signal. Only refusal materializes error text; the slot copies no rows.
  One Wasm task, observer channel and callback survive abandonment
  until physical retirement. Store close uses the same task/channel boundary
  to join Web Lock release; dropping a Store retains its backend until retirement.
  Host-bound Work and restoration add one original-LocalSet delivery task and
  channel, admitted before physical I/O. Restoration adds one acknowledgement
  channel, two raw IDs and two temporary ID cells; each cell uses one Rc allocation
  while its callback runs. Physical attachment custody is a fixed counter and Rc
  guard, independent of buffered-result lifetime. Raw abandonment parks each
  occurrence before signalling; only caller consumption creates the two ordinary
  capability guards. Delivery does not copy payloads or create another runtime.
  These task/guard costs are separate from the bounded Plan input allowance.
  `calls.advanceProgress` checks the Vat's pending-retirement predicate in
  constant time and uses its existing runner boundary only when state is retired.
  It reclaims endpoint slots without an application call, extra queue or copy;
  ordinary Vat boundary allocation and trimming retain their existing owners.
  Shared `Batch.Evaluation` keeps only scalars and
  immutable batch views; its inline C Work/Store cursor adds fixed startup
  state with no per-plan heap allocation or backend borrow across suspension.
