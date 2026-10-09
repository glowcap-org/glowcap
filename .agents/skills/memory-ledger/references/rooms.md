# Rooms session memory costs

The [memory ledger](../SKILL.md) owns the naming procedure. Derivations live
at each declaration; this inventory names managed session execution costs.

## The ledger

- **Receipt observation**: `content::receipt_observation::initialize` owns one
  weak actor per session. Each admitted read retains a bounded operation ID,
  original source and watch state through the existing bounded activity queue;
  content, grant and executor changes share the two session feeds.
- **Browser receipt wake**: `ManagedOperation::observe` retains one receive
  promise and one completion wake per original command. Unrelated workspace
  changes reuse that read; timeout or refusal wakes the existing viewer wait.
  Repeated timeouts retain no losing races or abandoned workspace waiters.
- **Membership diagnostic projection**: `membership_status::membershipStatus`
  retains one bounded prior failure map sharing its report's scalar strings.
  Only changed failures enter the journal; directory projection uses its
  existing map directly.
- **Terminal observation diagnostic**: `results::Settlement::unknown` bounds
  one formatted failure to 4096 UTF-16 units. The existing settlement envelope
  and receipt codec retain it through retry and cold restoration. It owns no
  returned capabilities and grants no permission to repeat a target call.
  `records::check_reservations` reserves its worst-case JSON and fragment growth
  before dispatch and across concurrent edits, without another custody scan.

- **Durable public room lookup**: `Authority::reindex_publications` derives one
  scalar publication-to-room index from persisted room and policy generations,
  bounded by `document::MAX_ROOM_LINKS`. Restoration and validated authority
  successors rebuild it; admission borrows canonical room fields through a
  logarithmic lookup. It retains no descriptors or live rooms. Named directory
  replies own their bounded wire descriptions; subscription alone realizes
  a dormant room.

- **Accepted process connection shutdown**: `Peer.connections_stop` owns one
  shared watch allocation and at most `CONNECTION_LIMIT` receiver handles in
  existing connection tasks. It cancels admitted remote waits before attachment
  retirement while retaining the Host needed by owned consumer cleanup. No
  payload, capability inventory or additional per-connection task is copied.

- **Browser conversation selection**: `ManagedNavigation` retains at most one
  pending operation and one latest scalar choice. Rust command custody stays in the viewer's existing
  receipt owner. Visible selection changes immediately; ordered settlement
  cannot restore an older view. Close drains the active gesture before dropping
  its scalar choices.

- **Membership standing**: `standing::Standing` retains one acknowledged reason
  and at most one pending reason/Command under the shared 120-unit Standing
  bound. The membership lends its existing submission owner to admission; one
  Rc command shell preserves exact intent across independent waits.
  `Worker::apply_standing` consumes the wake's owned snapshot without copying or
  reading it again. Pending commands discard that snapshot; conflicts and settled
  receipts refresh intent through the original source.

- **Room post reply**: `lines::posted_reply` owns one fixed two-element argument
  spine containing the authoritative notification ID and the moved line
  capability. Text, file and retained posts share this exact result contract.

- **Managed browser draft conflict comparison**: `ManagedDrafts::stage` retains
  one serialized scalar conversation identity and the accepted draft string
  occurrence per staged conversation, bounded by the admitted workspace.
  Neither a workspace snapshot nor held authority is copied. A proven admission
  conflict permits one comparison and retry; acknowledgment or retirement
  removes the row. Lost acknowledgments keep the original command owner.
- **Rooms topology lookup scratch**: `ManagedProjection.#topology` borrows one
  map of presented conversations, one archive-share map and one scalar line-ID
  set per visited conversation. They retire with the pass, copy no payload or
  authority and are bounded by admitted intent and existing presentation.
  `bench-rooms-projection` measures visits; the projection cost scenario rejects
  conversation rescans and repeated line-custody walks.

- **Archive conversation chronology** — `index::context::Contexts` holds one
  tree node and shared Entry root per retained record, bounded by index capacity.
  Borrowed context bounds copy no keys or payloads. Exact conversation reads
  traverse that conversation only; replacement, eviction and erasure release
  all indexes together. IndexedDB `records::codec::context` serializes one
  bounded context key per envelope; its compound index updates in the same
  transaction as the record and limits cursor decoding to the selected context.

- **Scoped process archive erasure** — `Store::clear_source` stages bounded
  index spines and shared immutable record roots until atomic journal commitment.
  Blob reference deltas release only erased records; payloads are not copied.
- **Managed history retention** — `retention::Owner` retains one bounded task,
  scalar shared-feed subscriber and original recorder source through erasure and
  receipt settlement. `Worker::reconcile` reads the canonical private marker;
  a timeout leaves the admitted backend erasure and durable receipt owned.
  Shutdown joins this worker before releasing archive or Loam storage.
- **Selected archive availability** — `recording::availability::Availability`
  owns one shared fixed selection cell with the canonical archive field key and
  a borrowed exporter Session shell. The existing retention task observes its
  end beside the shared change feed. Journal status carries only the exact key
  and original private source; queued delivery rejects replaced selections.
  No additional scheduler, capability inventory, file bytes or URI is retained.
- **IndexedDB scoped erasure** — `write::clear_source` owns one transaction
  callback and bounded row decode at a time through record and blob deletion.
  The existing retained mutation slot observes commitment after cancellation.

- **Rooms managed command custody** — `Workspace::prepare_command` admits
  borrowed strings, then owns one reserved envelope and one canonical
  intent through interruption and exact replay. `Request::canonical` serializes
  admitted borrowed arguments directly. The owning comments declare the copy
  and lifetime; local and remote fronts borrow the same retained request.
- **Source-owned publication link** — `publication_link::link_publication`
  borrows the exact admitted ID and moves a selected source handle into the
  existing bounded answer owner for foreign requests. No lookup snapshot or
  URI copy intervenes; the retained RoomLink result acquires the source recipe.
- **Browser signaling preparation** — `signaling::Preparation` retains the
  refused exact scalar selection in the existing per-directory owner table.
  It holds no capability or workspace snapshot. Replacement or explicit retry
  releases that bounded selection; unrelated workspace wakes cannot repeat it.
- **Direct introduction receipt**: `EffectReceipt::introduction` retains three
  inline custody coordinates, one bounded 36-unit registration string and one
  128-unit opening identity per
  registered contact admission. The existing receipt population bounds retention;
  persisted provenance prevents first adoption or reload recovery from attaching
  the result to a replacement local registration. It holds no capability mirror.
- **Rooms acquisition custody** — `AcquisitionRequest::new` moves imported
  capabilities and recipe strings into one final envelope and serializes the
  candidate once through a writer capped at `MAX_AUTHORITY_BYTES`. Its fixed
  four-argument owner and bounded import/release spines survive exact retry.
  `Acquisition` retains the original caller and source; submissions borrow the
  envelope. The trusted runtime writer uses the same encoding without a second
  candidate representation.
  Browser submission projects one bounded status string through
  `outcome::acquisition`; it copies no capability or candidate. A proved conflict
  releases the page's candidate handle. Unknown replies retain that handle for
  exact replay, and result conflicts retain the original command receipt.
  `Workspace::prepare_directory` clones one bounded candidate and hands two
  actual occurrences to that same envelope, retiring its temporary intent
  before submission. The source is the invoking workspace endpoint; no URI or
  publication inventory is retained for it.
- **Directory conflict re-preparation** — `DirectoryAcquisition::reprepare`
  retains the original bounded row alongside its immutable candidate. Only a
  proved conflict permits `Acquisition::recompose` to copy the original
  bounded import spines and recipe strings into a replacement; shared guards
  preserve the actual acquired occurrences. Both candidates remain charged
  until replacement handle admission succeeds. `Directory::retained_bytes`
  uses the application's exhaustive field accounting without serialization.
- **Operations conflict re-preparation** — `OperationsAcquisition::reprepare`
  retains the original workspace inventories (at most 64 rows each) and one
  replacement bounded by the boot capability inventory, with the exact envelope.
  Its replacement copies only after a proved conflict, checks the original
  bundle and preserves current connection custody for surviving gateways.
  `OperationsAcquisition::retained_bytes` charges both selection capacities
  and the complete envelope while both browser handles coexist.
- **Operations import refusal projection** —
  `RoomsManagedWorkspace::prepare_operations_acquisition` fetches each of at
  most six entries once and projects each failed entry's selected capability,
  diagnostic and shared repair advice. Successful temporary occurrences retire
  together if any fetch fails; no partial workspace candidate is prepared.
- **Workspace replacement retirement index** — `Intent::replace_configuration_retiring`
  indexes the candidate's bounded scalar occurrences once during managed acquisition.
  The declaration owns its capacity and callback lifetime; removed selections
  retire without a client release list or a candidate walk per old field.
- **Rooms result acquisition** — `Command::prepare_result_acquisition` retains
  the original source and copies its operation and canonical intent once into
  a seven-argument request in one shared allocation. `retained_bytes` charges
  its fixed spine, reference counts and payload capacities. Interrupted managed
  submissions share that owner instead of copying the candidate. Before adopting
  a manager or moderator, a temporary candidate and at most one page of scalar
  selections validate the actual result capabilities against the exact room.
  The result query and imported occurrence guards retire after this check.
- **Created room selection** — `ResultAcquisition::created_room` narrows a
  candidate to one bounded room recipe before handle admission. The session's
  `Request::created_workspace` copies current intent for atomic append, preserving
  intervening edits; receipt targets fence the exact original directory.
- **Moderator issuance reply validation** — `moderator::read` owns two transient
  URI projections and one retained moderator recipe through exact result save.
  `candidate_arguments` supplies the same bounded
  candidate encoding as ordinary ingress. Result mappings and release spines
  contain scalar coordinates, capped at one custody page. Runtime
  `imports::references` declares only original source, selected results and
  occupied destinations; graph replacement transfers their saved edges without
  another save or capability wrapper.
- **Browser result re-composition** — `ResultRecipe` retains only bounded scalar
  target signatures and original result/destination coordinates per pending
  receipt. `ManagedOperation::complete` coalesces preparation and recovery;
  completion replaces a candidate only after a proved conflict, at most four
  submissions. Each attempt owns one transient workspace candidate. Unknown
  outcomes retain the exact managed candidate; close drains its completion
  before releasing wrappers. No upstream effect or capability is re-fetched.
- **Rooms cold receipt custody** — `Workspace::recover_effect` moves one
  admitted canonical intent into `RecoveredEffect`, retaining the exact original
  invoking endpoint. Its queries own temporary argument envelopes through the
  existing Host call; result acquisition uses the same `results::prepare` witness
  and candidate encoder as a newly prepared command. `SessionContent::receipt`
  restores at most `MAX_EFFECTS` source fields for source-filtered inventory;
  its bounded descriptive rows and encoded reply retire after callback return.
- **Rooms browser handle custody** — `Driver::hold` bounds returned handles
  independently of queued jobs by count and owned bytes. Each request's
  `retained_bytes` accounts for its existing string and vector capacities,
  including canonical intent, without another serialization or payload copy.
  `Held` clones share one charge through JavaScript and queued submissions.
  Final drop releases capability custody on the creating LocalSet; fixed
  wrapper allocation and Rc counters are charged at the handle owner.
- **Rooms callback ingress** — `managed::inbox::demand` walks borrowed input
  before its one owning copy across source admission. One session `Budget`
  bounds queued and in-flight messages and bytes across every inbox; fixed
  actor, task and queue state is bounded separately by the workspace row caps.
  `Workspace::check_inbox` encodes only the immutable scalar selection, restores
  one exact source and its installed callback, returning no workspace payload
  or capability inventory. The worker retains one callback reference until drain.
  `InboxSelection` retains each directory's bounded requested nickname through
  callback retirement so committed edits fence admission before reconciliation.
  Direct requests also retain the existing delivering session and verb across
  admission. Capability replies use ordinary Host resolver projection and handoff;
  no separate reply cache or peer identity reconstruction is retained.
  Callback close drains deferred answers before attachment close; drop releases
  retained inputs and their aggregate charges.
- **Rooms membership supervision** — `supervision::Worker` owns one exact
  source, scalar inbox selection, shared change wake and task state per live
  membership. It checks that source through `Workspace::describe_access` after
  each wake, with no per-membership observation registration or cursor.
  `changes::Wake::inspect` lends one session-owned mutex to short inspections
  and preparations, bounding wake admission independently of room count.
  Upstream effects and parked feeds never hold that guard.
  Its four startup permits separately
  bound candidate-bearing acquisitions; command and result candidates retire
  after readiness. The session's task registry owns fixed lifecycle state and
  one stable worker identifier and one selected admission identifier per worker.
  `startup::Worker::run` retains the original scalar source through inbox
  installation, then drops it. This moves the existing source without another
  capability or string clone. Installation and result candidates are replaced
  only after a proved conflict, with at most four attempts; unknown outcomes
  retain the original request. Its admission ordinal suffix permits logarithmic
  exact retirement lookup. Weak budget links avoid a task/registry
  retention cycle. Failed cleanup keeps exact cancellation custody and its
  registry charge until a later close succeeds. Workspace reads are bounded
  temporary snapshots, with no retained full snapshot per live membership.
  `workspace::Submission` retains one boxed actual admission receiver during
  startup or interrupted close. `supervision::retirement::Owner` holds one
  private exact returned name/seat and one interruptible leave receiver per
  directory/room worker. Direct workers share that bounded Rc owner for lifetime
  observation without retaining a raw route. The worker lends its existing writer
  Rc and holds a weak registry link for sibling connection accounting. Each
  owner retains one borrowed exporter-session view;
  `ended` observes the existing connection without a task, payload copy or dial.
  `expire_connection_lease` holds one bounded candidate through exact acquisition of
  alias retirement. Its configuration replacement uses the existing retirement
  index and preserves durable entrance and reconnect intent.
  The registry admits at most the workspace's 32 directory
  and 256 conversation rows in total, charging failed cleanup and unspawned
  startup candidates before admission. Starting tasks also keep their startup
  permit until readiness; this conservative charge never exceeds that bound.
  No raw-authority lookup map or public bypass is introduced; unknown upstream
  outcomes preserve the registry charge and refuse cleanup.
  `changes::Owner` retains two private observation workers and one watch channel
  per session: content use and management inventory. `Wake` holds a scalar watch
  receive/send handles and their two retry signals per worker;
  source observations poll after a wake instead of retaining a receive call.
  Exact source and cancellation custody remain at each membership. The shared
  feeds own their requests and receiver/canceller through shutdown or retry.
  `changes::Receive` retains one boxed admitted receive per feed across
  interruption, and drains that same future after cancellation. It adds no
  cursor or capability copy and bounds parked calls to one per feed.
  Terminal execution wakes reuse that watch channel without allocation, content
  copies or an additional observation registry.
  `SignalingRegistration` retains one mediated route, membership handle and
  shared-feed wake per registered directory. Its worker retains the original
  source and bounded scalar selection; each check encodes that selection into
  call-owned temporary input, without retaining a workspace snapshot. Readiness
  waits for both shared feeds. Failed observation retains the registry charge
  and retries those same feeds. The facade owns its exact scalar selection
  under the existing continuation budget. The route
  holds the existing directory exporter for handoff identity; it creates no
  transport session. Its facade discloses the six signaling methods only.
  Browser signaling holds one listener worker and route entry per directory,
  bounded by `workspace::MAX_DIRECTORIES`. It retires and joins the original
  worker before a successor files an inbox. Admission pressure stops its inbox;
  refused sessions are joined before reopening. Reconciliation owns one temporary
  workspace snapshot and retains only row identifiers between wakes.
  Worker startup compares two fixed 33-byte `resource-key` reply projections,
  then discards both. Neither source receives the private root as an argument.
  `Memberships` owns one scalar origin and handle per desired row, capped by
  live inbox admission. Reconciliation borrows one temporary index from the
  admitted intent, copying one identifier at a time across retirement waits;
  it retains no second workspace payload or upstream capability inventory.
  `Worker::run` samples known failures before restoration waits. One temporary
  report copies only failed target identities under the worker population bound;
  ready counts borrow worker status and allocate nothing on a healthy wake.
  `Origin` also owns each directory's bounded requested nickname so an edit
  retires its worker independently of the registration's assigned name.
  `RoomNickname` owns one bounded current name and scalar registration key in
  worker, callback and coordination selections; matching borrows current intent.
  Notification consumers borrow the checked initiating endpoint. Each room
  or directory worker holds one additional guard so retained files can keep that
  exact occurrence without resolving newer workspace custody.
  `InboxOrigin` shares one bounded selection, original source and installed
  callback across child line workers through one Rc shell and weak live guard.
  Child admission uses the existing queue and aggregate input allowance.
  `Session::receive_line` admits consumer-derived actor metadata under a separate
  aggregate byte allowance before construction. `LineMemory` reserves positive
  refile growth from the complete validated selection before copying persistent
  metadata; rollback releases tentative growth and commit releases shrinkage.
  The final resized charge survives through actual worker retirement.
  Its callback count shares inbox
  admission; the existing task registry owns line retirement through reply drain.
  Line identity allocation uses one inline counter, with no line lookup table.
  `Session::on_trouble` installs one boxed embedding reporter at the Writer before
  work starts. The inbox budget holds one weak Writer link; refusal reports borrow
  their evidence and add no queue, session retain or persistent payload copy.
- **Managed Rooms activity** — `Activity::prepare` reserves one normalized
  scalar projection, accepted attachment metadata, fixed file actor state and
  Rc shells before publication. The 4096-entry ring and 16 MiB live byte
  allowance are shared by every viewer; `Charge` remains with held events and
  file actors after ring eviction. Entry roots own precreated file actors so
  content disclosure performs no Host reentry. Each actor retains the event
  and one lazy upstream reader; the event holds no actor root. Direct line
  roots have independent count and byte admission at `LineMemory`; display
  eviction cannot retire their editing lifetime. `LineChanges::reserve` admits
  metadata and presentation before committing either; previews retain only
  URLs still present after an edit. Reader tasks share a 16-call bound and weak
  Activity links across waits. Close retains unresolved reads through retry.
  Projection JSON is the one retained presentation encoding, independent of
  durable archive recording. Projection JSON contains no capability recipes.
  A private incoming offer retains one validated URI under the same event byte
  charge, and at most one owned prepared capability occurrence. Preparation
  verifies its exact recipe before retaining it; retries reuse that occurrence.
  Event retirement releases both even when acquisition never commits. Scalar
  mutation receipts retain committed acquisition identity after event eviction.
  Handed room and archive authority saves one live dependent facet through
  `Entry::dependent_source`, retaining its original session source. Recipes
  use ordinary validated saves; no bearer is invented for a live handover.
- **Managed archive sharing** — `archive_sharing::Pipeline` holds one confirmed
  continuation with exact archive and recipient targets. Live narrowing retains
  one boxed read observation or its terminal result, then moves the recursive
  read facade into delivery. Durable issuance and delivery each retain one
  `EffectExecution` across interrupted waits; replay observes that execution
  without dispatching again. Terminal Unknown retires the execution and leaves
  the durable receipt unresolved. At most one prepared result and one
  pending execution coexist per bounded session effect. Filters and recipient
  labels follow the application's admitted text and archive scope limits.
- **Managed browser activity handles** — `RoomsManagedActivityReader::read`
  decodes the bounded envelope and one event projection for the JavaScript
  boundary. Incoming classification borrows that event's scalar notice kind
  without constructing another Rust JSON tree. File wrappers
  retain dependent readers and descriptions under Driver's handle/byte limits;
  reads copy only their bounded chunks across Wasm. Incoming wrappers retain
  an exact workspace and incarnation-bound token, never upstream capability
  reconstruction. Prepared acquisitions own one immutable request/sequence
  spine through replay. Dropping a viewer cannot retire the source's direct
  line actors or membership supervisor.
- **Browser file displays** — `attached::file_display::materialize` is the
  single Blob/URL owner for managed incoming files, exact archive attachments,
  and the remaining legacy file fronts. The Environment's receiver budget
  reserves logical size before the first read; bounded chunks cross Wasm once
  and feed a browser Blob without a second complete Wasm buffer. The returned
  URL retains its charge until release/Drop. Static reader implementations
  retain exact custody and recheck admission on every chunk. Cancellation
  drops the partial materialization and charge. Archived opening owns one
  validated bounded record and its display metadata during lookup and reading;
  it adds no retained blob wrapper or independent receiver budget.
- **Local command observation** — `Commands::submit` retains canonical
  request material and one actual Submission per operation, bounded by the
  effect count and 16 MiB input allowance. One Rc shell per retained Command
  permits independent socket waits outside the registry lock; watch clones copy
  no request payload. Release fences the exact shell before removal.
  Socket deadlines lend a wait to this
  owner. `Feed::receive` retains the shared event after journal acknowledgment;
  the journal ID names that exact custody until acknowledgment or retirement.
  Disk presentation does not retain or reconstruct capability authority.
- **Local inbox pages**: `Inbox::pending` copies one borrowed journal slice into
  a socket response, capped at 64 rows and the journal's 16 MiB byte allowance.
  Identifier paging uses binary search and retains no intermediate reference
  vector. The listener retains only its event watermark and independent wake
  cursor; delivery leaves the durable journal pending for acknowledgment.
- **Managed direct transition recovery** — `introductions::Pending` retains one
  Rc request, exact initiating source and complete callback/route arguments per
  transition, capped at 32 including failed entries. Its task observes the actual
  completion; only explicit recovery restarts a terminal failure with that same
  request. Successful completion releases its entry. No acknowledged callback
  or timeout can discard the sole recovery input.
- **Managed sender provenance** — `outgoing::Capture` retains one admission
  plan, original source, bounded caption, one fixed history identity, the actual
  selected recording writer and at most eight exact file edges in
  each of the eight effect workers. `Activity::prepare_outgoing` reserves one
  immutable event before dispatch and shares its source and file vector with
  recording. Admission reserves its byte charge without Host reentry; the
  confirmed executor prepares file actors before remote dispatch. Private
  settlement publishes it once into the bounded journal;
  `activity::Origin` retains the exact source and generational line key for
  every queued read. The receipt stores the same immutable plan
  before dispatch; settlement moves its coordinates into private sender custody.
  `Origin` persists independently of receipt eviction, capped by line custody.
  `check_reservations` measures one temporary origin encoding at a time and
  reserves future fields, workspace rows, provenance, result bytes and fragments
  against the existing aggregate profile. Its temporary coordinate set and
  admission's slot selection carry scalar keys only. The durable `next_identity`
  counter supplies fresh generations as well as sender IDs; only the first
  custody page is rewritten when it advances. `retain_repeatable` shares the
  existing source backing across independent archive and recipient reads,
  under the original byte, source and read limits. Hosted leases retain that
  backing until reference retirement; source-owner shutdown still expires it.
- **Admitted archive writer** — `Peer::held` retains one bounded target and
  standing memo through capture completion and both storage writes. It uses the
  actual admitted capability and takes no ownership of the shared connection.
- **Deferred archive restoration** — `recording::destination::Target` retains
  the existing private writer and exact selected archive coordinate. The
  archive worker resolves it under a deadline after message delivery, with
  retained bytes charged to archive admission. No current-selection lookup,
  additional task, URI inventory or capability mirror is retained.
- **Combined history view** — `Archive::read_together` scans each account under
  its declared row bound and uses the application merge owner. The result spine
  shares each winning Record and carries its exact reader index. The browser
  projects that bounded spine once; `ManagedHistory` lends a temporary map keyed
  by those same record objects while file views retain their supplying reader.
- **Managed bridge custody** — `bridge::Pipeline` retains one exact form
  observation, credential-write future and submit observation in the existing
  eight-worker bound. Public declarations and answers have the shared form
  limits; private answers are combined only for target dispatch. `Witness`
  retains the original source and independent continuing access in the existing
  custody profile, with at most 64 witnesses beyond receipt eviction.
  `credential_snapshot` encodes only witness IDs and nonces, below 8 KiB, with
  one temporary scalar spine and no capability restoration or JSON value tree.
  `allocation::Allocator` shares the admitted slot set with sender execution.
  `check_reservations` keeps 64 acknowledgment bytes and one possible fragment
  per unresolved bridge, in addition to the complete already admitted witness.
  `retention::Owner` adds one scalar subscriber and at most one complete
  reconciliation future. It retains the credential admission fence before
  snapshotting Loam, preventing cleanup from erasing a later staged write.
  Deadlines lend a wait to that future; retry and shutdown observe its completion.
  `executor::Action::Bridge` boxes the admitted bridge intent until the worker
  transfers it into Pipeline; other action phases retain only a pointer-sized
  variant allowance and no bridge payload copy.
- **IndexedDB credentials** — `Credentials::read` validates the stored byte
  length before one structured-clone-to-Rust copy. `Credentials::replace`
  transfers bounded document bytes to one browser serialization and the existing
  `Operation` transaction owner. Cancelled observers leave that operation in
  the document until actual completion. Tab startup creates the single document
  only after acquiring its Store lease; opaque owner identity scopes its key.
- **Native local acquisition observation** — `Acquisitions::submit` retains
  exact serialized request identity and one task per bounded acquisition. The
  typed candidate and capability bundle retire after Host admission; the
  generalized `Submission` keeps the actual result receiver across socket
  interruption. Workspace and result acquisitions share this lifetime contract.
  `control::RequestBody::Acquire` boxes only its decoded candidate until execute
  moves it into that admission owner, avoiding candidate-sized socket state for
  every other request.
- **Rooms workspace observation** — `watching::Worker` retains one exact
  source, observation request or receiver/canceller pair and cursor. It retains
  one boxed `changes::Receive` across reconciliation and retry interruption;
  cancellation drains that exact receive before releasing the attachment.
  It borrows one bounded snapshot during reconciliation; workspace changes interrupt that
  observer while the registry preserves already-created membership workers.
  `ownership::spawn` owns fixed task/channel state at the existing lifecycle
  seam. A separate singleton registry and weak session link avoid retaining
  the observer through its own session or nested membership handles. Failed
  cancellation keeps both registries and their exact custody until retry.
  `watching::Refresh` shares request and recovery generations, a recovery flag,
  Notify and Rc shell per
  session. A viewer gap coalesces requests; the worker drains existing discovery
  custody before admitting fresh snapshots and retains no second inventory.
  Connection loss activates bounded transport recovery backoff at this owner;
  each workspace worker retains one delay scalar, with no timer per membership.
- **Established browser publication home** — `PublicationHome::remote` moves
  one admitted original URI into `Driver::hold`; derived handles share its
  count/byte charge. Publication parses temporary route data and formats the
  exact original owner's returned name. Foreign saves move that established
  recipe into the existing acquisition envelope, without another authority map.
- **Trace socket admission** — `connection_head` retains at most 4096 consumed
  bytes for exact replay into CapTP or WebSocket; connection count and handshake
  deadline bound custody. Its declaration owns the separate HTTP parse scratch.
- **Trace retirement** — `Publisher::run` retains the actual socket across a
  failed physical close. Explicit close retries that barrier without connecting
  again; `Trace::retire` keeps the publisher until physical retirement succeeds.

- **Directory opening offers** — `registry::inboxes::Offers` retains bounded
  peer and opening keys with each actual inbox occurrence until introduction
  transfers it or either registration retires; borrowed lookup retains no copy.
