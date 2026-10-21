# Shared Rooms hosting and sign-in

Status: active plan, waiting for maintainer review before work starts.
Delete this plan when its steps land and its roadmap item closes.

## What this is for

Rooms sessions keep the same capability model whether owned in a browser,
run locally or hosted together on a server. Shared hosting serves many
independent sessions. Optional accounts remember explicitly entrusted access
and offer sign-in recovery. Creating, using and sharing a session needs no
identity-provider account.

The design spends memory and execution capacity on active work. Creating a
session on a shared host must not create a process, thread, Host, listener
or database cache.
Sharing infrastructure must preserve separate authority, personas and costs.

## Where things stand

The session service composes one workspace, Host, transport runtime, SQLite
Store and archive. Its bootstrap persists separate Host, Store and owner
identities, but its lifetime owner closes the composition together.
The [session guide](../rooms/session.md) owns the existing contracts.

Directory registration and room membership currently select people through
their connection. Directory tests require one name per connection. Reconnect
can recognize the transport's durable identity. Those assumptions prevent
independent personas from sharing a Host's connection to a directory.

Loam can hold multiple resources and attachments can share a Store. Its
attachment allocates arrays from configured limits, and a Store has one write
lane. Merely creating the current session composition repeatedly would retain
large per-session infrastructure costs even inside one process.

No account service or identity-provider integration is established by this
plan. No hosting-density or process-cost measurement has been performed for
it. Protocol connection counts are not evidence of Rooms session capacity.

## The decision

### Preserve capability authority across every deployment

A Rooms session is an application resource, not a CapTP connection, account
or authenticated person. Its persona gives conversations continuity.
Transport identity authenticates the hosting peer. Provider identity proves
a login to an account service. None of these identities substitutes for a
capability to use or manage a session.

| Session placement | Authority and lifetime |
| --- | --- |
| Browser-owned | The browser owns the session and local storage. Local use needs no server or login. Publishing enables remote access only when requested. |
| Local process | The process owns durable state and can run unattended. Local calls need no network round trip or account service. |
| Shared host | Independent roots borrow pooled infrastructure. Creation requires hosting-allocation authority, which can be held without an account. |
| Attached browser or agent | A client holds access to a session elsewhere. Its view lifetime is separate from the session's lifetime. |

Placement, sharing and account custody are independent choices. Any supported
placement can share scoped use or management through capabilities, subject
to its reachability and lifetime. A browser remains a peer that can host
objects, receive calls and pass references. This plan does not turn it into
an HTTP-only client or promise that a closed browser remains available.

Keep one session implementation and admission contract across these paths.
Standalone and browser compositions may own their infrastructure directly.
They do not need a placement service, account database, server worker pool or
network hop for local operations. Shared hosting adds composition and
scheduling around that model, not a second session type.

An account is an optional custodian of capabilities explicitly entrusted to
it. Login can recover only that authority. A session identifier, provider
claim or database association cannot recreate access or authorize an effect.
Account deletion must not delete a session or revoke independently held access
unless separate authority explicitly authorizes that operation.

The session owner decides whether to entrust use, management or recovery to
an account. Adding that relationship neither migrates the session nor changes
its persona. Removing a saved entry releases custody, while revoking its
source grant is a separate authorized act. Independent holders remain valid
under their own grants, without enrolling in the same account service.

OCapN reference passing, callbacks, promises and supported handoffs retain
their protocol meaning. Rooms permissions and dependent guards are application
policy on the receiving object, not changes to CapTP. A passed reference
retains its authority ceiling and lifetime. A receiver never gains the
sender's account, and the target never requires the sender's login identity.

A view-scoped endpoint can be passed like any other reference, but all its
holders share its declared expiration when that view closes. Connection
ownership is a cleanup trigger, not an identity check on each invocation.
Sharing access that must outlive the view explicitly acquires an appropriate
durable grant when the source permits it. Do not claim that a bearer
capability cannot be copied or forwarded.

The pooled publication format belongs inside an opaque application Swiss
number. It changes neither the OCapN locator grammar nor CapTP messages.
Peers need no knowledge of storage partitions or accounts to pass and invoke
references. Rooms-specific application interfaces may require compatible
Rooms peers, but ordinary capability transport does not require Loam or OIDC.

### Separate execution from storage

A hosting worker owns one Host, transport runtime and serialized application
executor. It runs many Rooms sessions on one reactor thread. A process can
run several workers and shares a bounded disk-worker pool and memory ceiling.

A storage partition owns one Loam Store, attachment, SQLite database and
write lane. A worker can host several bounded partitions. Start with one
worker and one partition. Add partitions for measured storage contention and
workers for measured execution pressure. Neither count follows session count.

| Owner | Keeps |
| --- | --- |
| Process | Disk-worker pool, global memory ceiling, handshake admission and shutdown supervision |
| Hosting worker | Transport identity, connections, publication routing and fair work queues |
| Storage partition | Store, attachment, write lane, bounded cache and activation index |
| Rooms session | Durable resource root, persona, held capabilities, receipts, archive selection and active memberships |
| Account | Linked login identities and explicitly retained access to sessions |
| Account login attachment | One account-acquired device view's admitted access and revocation lifetime |

Session identifiers and account identifiers are descriptive. A held grant
selects authority. A callback receives its owning resource from the admitted
endpoint, never from a caller-supplied session identifier.

A shared Host identifies the hosting peer, not the person speaking.
Co-hosted sessions are correlatable through that identity. Deployments needing
separate network identities use separate workers, without requiring separate
processes. Authority separation does not provide anonymity between personas.

Process-per-session duplicates infrastructure. One database for the fleet
concentrates writes and storage failure. Tying every database to a separate
Host makes storage tuning change transport identity and connection counts.
Keep these ownership boundaries separate, with bounded totals at the process.

### Make membership an application capability

The [Rooms resource contract](rooms-design.md#operation-authority) remains
the owner of directory, room and conversation permissions. Its directory
and membership implementation must support several independent holders on
one CapTP connection. This plan adds the multiplexing requirement, not
another grant system.

A directory entrance admits a registration capability. Its durable grant
owns the right to resume that registration, and its current incarnation owns
the inbox and signaling endpoints. A room entrance similarly admits a
membership capability. Posting, editing and introductions select that
membership through the receiver, not through the transport connection.

Reconnect presents exact retained registration authority. A common Host key,
nickname or account never substitutes for it. Replacing an inbox advances
its incarnation. Late disconnects and replies cannot retire its replacement.
Closing a connection retires its live attachments, not their durable grants.

The same peer connection can carry calls for many personas and devices.
Transport authentication still proves the peer and protects routing.
Signaling binds an offer to the selected registration's current inbox and
the authenticated hosting peer. Shared transport identity cannot select a
sibling registration. Unkeyed routes retain their existing proof limits.

Several people using one Rooms session deliberately act as its persona.
Separate authors use separate sessions and share a room. Account sign-in
does not rewrite message authorship or nickname ownership.

Replace the unreleased Rooms application contract and all shipped consumers
together. Establish application compatibility before admitting a persona.
Refuse peers with connection-selected membership, without inventing a CapTP
version or preserving the replaced application API. Never silently combine
personas or allocate private Hosts as a hidden fallback.

### Pool storage and activate only needed state

Each partition stores session roots, grants, receipts and its activation
index in one Store. A shared behavior registry selects per-resource state through
the admitted receiver. It does not capture one mutable current session.
Runtime tables and attachment capacity are bounded per partition and charged to
the resource using them. A session has a storage quota below the partition's
physical limit, including its receipts, grants and retained content.

Logical session quotas do not bound physical database growth. Reserve partition
headroom for the largest admitted transaction, WAL and reclamation work.
Bound readers that can pin old storage. Refuse new writes before consuming
that reserve, and retain the existing uncertain-write recovery behavior.
The hosting allocation also accounts for metadata and unclaimed creations.

Operator bootstrap retains a hosting allocation capability, separate from
session use and management. Its holder creates sessions through the same
capability API used by later account services. Creation returns separately
held use and control capabilities. Ship an operator command for this path,
with no implicit public allocation or account registration.

Use the bound resource's Store identity, owner identity, slot and generation
as the runtime selection key. Requirements remain pure declarations and do
not activate a session. After authorization, invocation and forwarded-call
admission resolve the same owning state and retain it through completion.
No callback selects state from a transport peer or a mutable global binding.

The current invocation callback exposes bound resource metadata, but the
forward-admission callback exposes only the operation and its byte count.
Extend that shared callback contract with the already resolved source
resource. Do not infer it from grant inventory or introduce a per-session
copy of the schema registration. Foreign target metadata remains untrusted.

Cold sessions retain durable records without workers, timers, open files or
reserved maximum-sized runtime tables. A retained remote endpoint may keep
a small routing object. It need not pin the workspace's content in memory.
Activation loads the required records through a bounded queue and coalesces
concurrent opens. A failed activation returns its exact failure.

The lifecycle is cold, activating, active, draining, then cold again.
Deletion is a separate terminal transition. Generation-checked entries join
concurrent activation requests without duplicate workers. A waiter owns a
bounded reservation, and cancellation releases only that waiter's share.
An uncertain commit fences the affected storage owner until recovery.

Keep a durable index of sessions with required background work, updated in
the same transaction as that intent. Restart visits that index in bounded
batches rather than opening every stored workspace. Recovery priorities
cannot starve new work, and cold data cannot conceal an unfinished effect.

An unattended session that is connected to rooms or recording messages is
active. Closing its last browser must not stop that work. Eviction requires
no active membership, admitted effect, callback obligation or unresolved
cleanup. Bounded polling cannot stand in for an idle wake mechanism.

Host restart fences live references once at their shared lifetime owner.
Session deactivation has a separate generation for its callbacks. Opening
or closing one session must not advance the worker's epoch or close its
attachment, Store, listener or Host.

The Store retains serialized writes. Admission bounds transaction size and
offers queued writes fairly across sessions. Reads use the existing storage
execution contract. Disk work leaves the reactor through a bounded pool.
No network wait holds a write transaction. One slow fsync can delay that
partition's commits, which is a reason to bound partitions rather than promise
independent write latency inside one Store.

Session creation atomically installs its root, index entry, ownership result
and receipt before publishing access. Retries recover the same result.
Deletion fences new work, revokes owned access, drains effects and reclaims
bounded batches. Tombstones prevent an old reference from naming a later
session. Cross-partition operations retain explicit receipts and unknown outcomes.

Recording needs the same ownership separation. The current archive facade
keeps session-specific selection and pause state beside a worker and backend.
Sharing that facade would couple sessions, while copying it would retain
per-session infrastructure. Keep a lightweight session recorder with its
own selection, pause and source authority over a shared bounded executor.

The executor owns the physical archive backend and accounts for work by
session. Source identity comes from trusted session state, never a submitted
filter. Reads, shares, deletion and recording changes must preserve source
isolation, including blob retention and pending captures. Preserve today's
recording behavior without requiring the recursive content model to land.
The Rooms content plan owns any replacement of the archive format and policy.
No per-session archive worker or maximum-sized private cache is permitted.

### Bound work before allocating it

Admission checks process, worker, partition, hosting allocation, session and
grant budgets. Unauthenticated
traffic has its own bounded handshake and parsing allowance before any
session can be selected. A caller cannot evade its limit by minting more
grants, and limits cannot evict another session's active custody.

Runnable sessions receive bounded turns from a fair queue. Charge bytes,
pending calls, retained replies, activated records and disk requests at the
owner that admits them. Deficit scheduling selects independent ready work
before protocol admission. One session's ordered commands remain ordered.
Wake only runnable work.

The quota owner comes from the admitted resource, even when a capability is
forwarded by another account. Scheduling metadata conveys no authority.
Bound fan-out and synchronous callback work as well as ingress. A single
large room notification must yield between batches rather than monopolize
the reactor. These are trusted application callbacks, not a sandbox for
arbitrary user code.

Reserve capacity for cancellation, revocation, receipt settlement and
shutdown. A saturated send queue must still permit the owner to revoke the
sender. Calls already admitted keep their declared completion semantics.
Revocation prevents new admission and fences queued work before effects.

Shared connections introduce head-of-line pressure. Fairness selects which
independent application turn can produce sends. Once a turn admits sends,
the existing protocol queues retain ordering, provisional slots and handoff
dependencies. Never reshuffle encoded frames or add a second send queue
above CapTP. Admission reserves the turn's bounded reply and send capacity.

Limit frame size and queued bytes, and stream files as bounded chunks.
Protocol progress and cleanup consume their own reserved capacity. Bytes
already queued on an ordered stream cannot be preempted. A stopped remote
reader stalls every persona using that peer connection. Other peers must
continue, and the service must expose the shared blockage honestly.

A separate worker can isolate connection pressure, but cannot make an
unresponsive remote service progress. The pooled service promises bounded
interference, not independent throughput for personas sharing that stream.

### Keep account acquisition optional

The [account custody contract](rooms-hosting-accounts.md) owns OIDC login,
attachment issuance, revocation and recovery trust. It is a separate delivery
built on the capability-based hosting model. Normal session calls do not
pass through the account service, and account-free paths allocate none of
its login state.

### Route publications without scanning partitions

A Host currently installs one publication-lookup callback. Multiple Stores
need one worker-owned router there, not a sequence of probes through every
Store. A public routing discriminator selects a partition, and the remaining
unpredictable capability name is checked there. Routing metadata grants no
authority and cannot select a broader fallback when lookup fails.

The application publication envelope carries a version, stable partition
identifier and capability entropy. Preserve the full security strength of
the random capability name. Bound decoding and refuse unknown versions,
partitions and malformed names before storage work. Existing names require
explicit refusal if unsupported, never guessed routing. Apply the prerelease
policy rather than adding a legacy decoder for an unreleased format.

The full namespaced name must be identical in warm publication, cold lookup,
retirement and saved recipes. The current durable-name parser and publisher
use a fixed entropy format. Extend their shared contract and bindings rather
than prepend a string only at the Rooms edge. Test equal entropy in distinct
partition namespaces, including after restart and retirement.

Partition creation durably records its routing entry before publication.
The entry is inactive until exclusive Store ownership is established.
Retired partition identifiers are not reassigned. A partition fault stops
that partition's lookups without making siblings unavailable. Measure
unknown-name floods and lookup cost as partition count grows.

### Scale and move the actual owner

Placement chooses a worker and partition with available budgets for new
sessions. It is not consulted on each application call. Adding a partition
within a worker adds a write lane without changing its transport identity.
Adding workers distributes CPU and connections. All caches, connection
capacity and pending I/O still fit the process's total budget.

Move an entire worker's identity and partitions together for planned
machine relocation. Stop admission, drain or record unresolved work, fence
old writers, transfer durable state, then reopen under exclusive ownership.
Routes must preserve the identity for existing references to remain usable.
Address-based locators need explicit route preservation or reissuance.

A partition can change its storage location under the same worker and routing
identifier after it drains. Moving it to a different Host is not just a
placement update, because published references name the old peer. Individual
session movement across Stores also needs capability-aware transfer of
records, publication continuity and original receipts. Neither is promised
by changing an identifier in the placement table.

Local directory locks do not fence another machine. Automated failover needs
storage-enforced fencing before a replacement serves. Without that, movement
is a stopped, verified administrative operation. SQLite WAL is not a
multi-machine coordination service, and a stale replica cannot be promoted
as though it contained every acknowledged receipt.

A standalone session uses one worker and one partition. Reopening state in
the supported format preserves its identity, Store and grants. New sessions share workers and
partitions. Importing old sessions into shared Stores requires the explicit
transfer contract above. Do not rewrite their locators or copy records as
an apparent migration shortcut.

### Change the layer that owns each cost

Rooms owns membership identity, account policy, activation and session
lifetime. The Rust composition owns worker and partition startup and the worker pool.
Loam owns resource identity, grants, durable effects and storage transactions.
The driver owns shared connection scheduling and transport pressure.

Keep identity providers and Rooms tenancy out of the CapTP engine. This does
not promise zero Zig changes. Generic missing support for pooled hosting,
bounded scheduling or owner lifecycle belongs in Loam or the driver, with
its C ABI and binding changes. Do not duplicate those mechanisms in Rooms
to keep the core diff small. Coordinate needed owner APIs with the existing
[typed hosted access plan](typed-hosted-access.md), without starting its
remaining work as an incidental dependency.

### Scrutiny and acceptance

| Challenge | Required outcome |
| --- | --- |
| Accounts and OIDC are disabled | Create, reopen, use and share browser, local and pooled sessions through held authority. No account records or login requests are needed. |
| A browser owns a session | Local operations need no relay. Remote peers can invoke published objects and return callbacks while it is reachable. |
| A reference passes to a third peer | Preserve supported handoff, promise and callback behavior without account lookup or sender-identity checks. |
| A view-scoped reference is passed onward | It works within the original ceiling and ends with that view. Separately issued durable access survives. |
| Account custody is added, removed or deleted | No implicit session migration, persona change or loss of independently held access. |
| A local operation runs with hosting disabled | No account, placement or server scheduling cost is introduced. |
| Two personas share one connection | Independent names, memberships, inboxes, receipts and revocation. Neither can resume the other. |
| One session floods writes or files | Bounded memory and queues. Sibling sessions make progress, and cleanup remains admitted. |
| A slow disk stalls commits | Bounded waiting and explicit timeout or unknown outcome. No reactor blocking or unbounded retry. |
| A session closes while another is active | Only its own work retires. Shared Host, attachment and storage remain usable. |
| A callback arrives after reactivation | Its old incarnation cannot mutate or retire the replacement. |
| Login completion is replayed or swapped | No second issuance and no access delivered to a different pending attachment. |
| A forwarded call comes from a sibling resource | Bound source selection charges and runs only the owning session. |
| Fair scheduling encounters a provisional send | Protocol order and the reserved queue position remain unchanged. |
| The account service restarts during device revocation | Its persisted fence prevents replacement issuance. Unconfirmed targets remain pending. |
| Repeated sign-ins run for years | Expired live attachment rows are reclaimed without permanent grant growth per visit. |
| Account creation loses a cross-partition reply | Recover the original created session and its access, with quota still charged. |
| Approval arrives after attachment cancellation | The same pending generation stays closed and cannot be replaced by replay. |
| Source access is revoked while a file reader waits | The next effect checks current authority. Already disclosed bytes remain disclosed. |
| The process dies after a committed effect | Recovery uses the original receipt and never blindly repeats the remote effect. |
| One session's resource data is malformed | Its restoration fails without substituting another root. A corrupted Store fences its partition. |
| A process panics or exhausts its memory | All its workers can fail together. Process supervision recovers them, without claiming memory isolation. |
| A target is unreachable during sign-out | The local login ends, acquisition stays fenced and remote revocation remains explicitly pending. |
| Another partition is opened under the same Host | Publication lookup reaches only the named partition, without scans or identity changes. |
| Another process attempts to open the supported Store | It cannot become a concurrent writer. Restore requires the old owner to be stopped and fenced. |
| An old Rooms server selects people by connection | Refuse the incompatible application contract before registering another persona. |

The resource model is:

```text
memory = process baseline + bounded worker and partition infrastructure
       + active session state + live grants and endpoints
       + bounded queues and caches
```

Cold session population primarily grows durable storage. Count activation
indexes, publication entries and retained endpoint metadata in measurements.
Any mandatory resident entry is a real per-session cost, not free metadata.
An activation path that scans every stored session fails this design.

Measure the current service and the shared service at equal durability,
workload and offered load. Compare 1, 100, 1,000 and 10,000 stored sessions
with independently varied active populations. Measure proportional set size,
resident memory, allocator bytes, threads, file descriptors and connections.
Report CPU, throughput, activation time, commit latency and tail latency.

Measure live attachment and receipt memory separately from durable grants.
Repeated sign-in must reclaim retired live custody rather than grow the
permanent grant inventory. Include account-service outage and pending device
revocation, without claiming that connection timeouts bound remote access.

These populations are experiment points, not capacity promises. Include
idle sessions, unattended recording, many devices sharing one session,
many sessions sharing one directory, a noisy neighbor and restart recovery.
Vary worker and partition counts independently to locate reactor and write
saturation without confusing them with session count.

Before changing the measured paths, preserve a reproducible baseline revision
and workload. Once the benchmark hold ends, measure that baseline and agree
memory and latency budgets before accepting a performance-sensitive change.
The target is no regression in existing single-session paths beyond measured
run variation, alongside lower pooled infrastructure cost. A regression needs
an explicit tradeoff review, not a larger budget chosen after the result.

Correctness work can proceed during the hold, but performance acceptance and
the hosting release cannot. No benchmark runs during the hold.
The design removes duplicated infrastructure structurally, but measured
cost and contention decide the supported deployment limits.

### Settle ownership before public contribution

Complete account-free shared hosting before opening the project for public
contribution. The reason is specific: membership selection, session lifetime
and publication ownership are boundaries contributors would otherwise build
on while this work replaces them. Public source alone does not promise API
stability, but a coherent implementation avoids unnecessary contributor churn.
This milestone is not a claim of stable release or arbitrary hosting scale.

| Before opening contribution | After the hosting milestone |
| --- | --- |
| Capability-selected registrations and memberships, with shipped clients updated | Optional account custody, OIDC and device recovery |
| One session model across browser, standalone and pooled execution | Conversation reorganization and broader recursive-resource UI |
| Shared storage, recording execution, source selection and lifetime ownership | Additional worker deployment and placement automation |
| Durable creation, bounded activation, admission and cleanup | Automatic failover or individual-session relocation, each requiring its own design |
| Measured single-session and pooled costs, restart and backup proofs | Wider capacity claims after representative measurement |

The initial supported host runs one worker with one partition. The two-Store
proof establishes routing and lifetime separation without requiring a
multi-worker operator interface. Scale settings do not follow session count.
Adding workers later must compose existing owners, not change capability or
session semantics. Stopped backup and restore are required now. Fleet
orchestration is not.

The first integrated proof uses two session roots in one Store and Host,
with two personas joining the same directory and room. Revoke one, reconnect
the other, close each in either order and reopen durable state. Include a
browser-owned session and a remote capability holder. Then test recording
and erasure isolation, queued effects and cold activation before accepting
the pooled service.

The [Rooms plan](rooms.md#hosting-prerequisites) owns the membership
prerequisites. Land its policy declarations, room grants and affected method
consumers, and directory registration authority with this work. Full content
reorganization and the generalized editor are not dependencies. Existing
operations must remain usable through their actual clients, including sharing
and revocation. Do not declare the broader Rooms plan complete or create a
second grant system to bypass it.

Apply the [prerelease policy](../../.agents/rules/prerelease.md): replace
unreleased contracts cleanly, update consumers together, and retain version 1.
Do not add migration shims merely for publication. Unsupported stored state
must refuse explicitly, never silently reset or acquire broader authority.
Any reset remains an operator action after preserving a backup.
Reopening supported state must preserve identity, exact grants and receipts.

Before publication, record evidence for every hosting acceptance row above
that does not concern accounts. Exercise the supported setup through shipped
clients, including a browser-owned session and two pooled sessions. Keep
normal recording, file transfer, sharing and revocation usable. Measure
single-session regressions as well as pooled savings. Passing doc checks or
the small architecture proof alone does not satisfy this release boundary.

Stop architectural refinement when these ownership contracts and acceptance
conditions have no known contradiction. Implementation must then supply the
missing evidence. If the first integrated proof fails a contract, fix that
owner or revise the design before expanding the service. Do not move a failed
acceptance condition out of scope merely to reach publication.

## Steps

Implementation starts after maintainer review. Each numbered step is a
separately reviewable commit with a focused proof. Keep the existing product
working between steps, and revise a step before starting if it cannot meet
that bar. The prepublication hosting milestone ends at step 11.
Steps 12 through 15 add optional account recovery.

1. **Record the authority contract.** Add an ADR for session, infrastructure
   and account ownership. Resolve the membership prerequisite with the Rooms
   plan. Specify incompatible-application refusal and preserve the baseline
   revision and workload before changing measured paths.
2. **Multiplex directory registration.** Land the owning Rooms registration
   capability with its policy declarations, and update discovery,
   introduction and signaling consumers.
   Prove two names over one connection, exact reconnect, sibling revocation
   and late inbox cleanup. Refuse incompatible directory contracts and
   preserve independently held room access.
3. **Multiplex room membership.** Land the owning membership capability and
   migrate posting, editing and cleanup, with the required room policy
   declarations and grant admission from the Rooms plan. Prove two personas
   on one connection, including passed references, callbacks and sibling
   disconnect. Remove the replaced connection-selected paths in the same change.
4. **Expose resolved source context.** Extend forwarded admission through the
   shared Loam callback, C ABI and Rust binding. Direct and forwarded calls
   must select the same admitted resource, including refusal and stale
   generations. Regenerate consumers and verify existing callers.
5. **Share session infrastructure.** Separate owned composition from borrowed
   runtime state. Prove the two-root scenario above with one Store and Host.
   Exercise shutdown orders, pending effects, reopen and local invocation.
   Run the same session contracts through browser and standalone composition.
6. **Route several Stores.** Add the shared publication namespace contract and
   worker router. Prove two Stores on one Host, equal entropy in distinct
   namespaces, warm and cold lookup, retirement, malformed names and restart.
   Verify ordinary foreign peers can pass references without decoding names.
7. **Share recording execution.** Separate each session's recorder selection,
   pause and source authority from shared backend execution. Prove that one
   session's erase, share, cancellation or shutdown cannot affect another's
   records, blobs or captures. Keep unattended recording and selected remote
   archive behavior intact without a private archive worker per session.
8. **Create and retire hosted sessions.** Add allocation capabilities, atomic
   creation, quotas and bounded deletion. Prove account-free creation and
   sharing, receipt replay, crash recovery and no sibling resource selection.
9. **Activate durable sessions.** Add the bounded activation and background
   work indexes. Prove cold reopen, coalesced activation, cancellation,
   generation fencing and unattended recording across restart. Measure any
   resident per-session metadata when benchmarking resumes.
10. **Bound shared execution.** Add fair admission at the allocation and effect
   owners. Prove saturation, storage refusal, cancellation and reserved
   cleanup progress without changing protocol send order. Compare both pooled
   density and single-session costs against the preserved baseline.
11. **Complete the publication prerequisite.** Exercise the supported host,
    process loss, graceful shutdown and stopped backup restoration. Prove
    writer exclusion, supported-state reopen and unsupported-state refusal.
    Document setup, capability-based creation and sharing, measured limits and
    recovery instructions. The shipped path requires neither OIDC nor accounts.
12. **Add account custody.** Store explicitly retained session access and
    provider identity links behind account capabilities. Prove independent
    use and management, cross-host access, denied enumeration and explicit
    adoption. Removing custody must not remove independently held authority.
13. **Add managed login attachments.** Implement target-owned pending, open
    and closed lifetimes. Test returned guards, passing references, replay,
    account and target restart, connection loss and pending remote revocation.
    Prove durable delegation remains separate and no fenced login reopens.
14. **Add OIDC acquisition.** Implement browser-bound redemption using a local
    provider fixture. Test issuer and audience checks, expiry, state swaps,
    replay, issuance restart and key rotation. Advertise Keycloak or Google
    support only after exercising that provider with operator credentials.
15. **Release optional account access.** Add sign-in, session selection and
    device revocation using the existing access UI. Prove two accounts,
    multiple devices and an account-free recipient. Re-run account-disabled
    setup and sharing, and document recovery trust and outage behavior.
    Remove this plan and its account contract when the roadmap item closes.

The changed contract chooses the check. Rust policy and persistence use
`rooms-rust-test`, browser ownership uses `rooms-browser-test` and the
applicable managed browser proofs, and server consumers use
`rooms-server-test`. Generic protocol-facing changes also require
`oracle-check` and the applicable external interoperability proofs.
The [build steps](../build-steps.md) and project gate rules own the exact
commands and final checks. Run them through the worktree environment front.

## Parallel work

Authority and lifetime changes are sequential. One integration owner owns
this plan, the roadmap row, the ADR and shared runtime interfaces. Coordinate
membership changes with the existing Rooms plan rather than assigning both
plans overlapping implementations. Do not split a shared contract by language.

After the hosting milestone, provider-fixture work can proceed independently
of account storage. Attachment issuance waits for the custody contract, and
provider acquisition waits for attachment issuance. UI integration follows
those contracts. Parallel work is optional, not a prerequisite for this plan.

## Questions for you

The hosting milestone needs no provider-recovery decision. Before the
account milestone, confirm provider-recoverable custody. Accepting it means
trusting the provider and host with the account's retained authority.
Provider-independent account recovery is a different custody product and
must not be implied by the sign-in interface.

Hosting scale will be published from the reference workloads above, rather
than assigned a universal session count. Public signup remains an operator
choice. A trusted login alone never enables unbounded session creation.

## Where the code is

- Single-session composition: `apps/rooms/rust/services/src/session/peer.rs`
  and `apps/rooms/rust/services/src/session/transports.rs`.
- Storage and bootstrap: `apps/rooms/rust/platform/src/storage/session.rs`
  and `apps/rooms/rust/runtime/src/session/managed/bootstrap.rs`.
- Runtime lifetime and budgets:
  `apps/rooms/rust/runtime/src/session/managed/opening.rs`,
  `apps/rooms/rust/runtime/src/session/managed.rs` and
  `apps/rooms/rust/runtime/src/session/managed/profile.rs`.
- Connection-derived membership:
  `apps/rooms/rust/services/src/server/registration.rs`,
  `apps/rooms/rust/services/src/server/rooms.rs` and
  `apps/rooms/rust/application/src/server/directory/tests.rs`.
- Shared storage constraints: `src/loam/hosting/attachment.zig`,
  `src/loam/hosting/live_epoch.zig`, `src/loam/hosting/discovery.zig` and
  `src/loam/hosting/publication.zig`.
- Recording composition: `apps/rooms/rust/runtime/src/archive/session/mod.rs`
  and `apps/rooms/rust/services/src/archive/file.rs`.
- Existing authority work: [Rooms plan](rooms.md) and its
  [resource contract](rooms-design.md).
- Capability semantics: the vendored [OCapN reference model](../../conformance/ocapn-spec/upstream/draft-specifications/Model.md#reference-capability)
  and [OCapN overview](https://ocapn.org/).
