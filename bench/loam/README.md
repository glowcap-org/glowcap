# Loam workloads

Run `zig build bench-loam -Doptimize=ReleaseFast` to measure the Host/Vat,
record-backed actors, and storage engine together. The Tasks workload runs on
each disk engine, and every other workload measures LMDB's own pages and file capacity. Output names the optimization
mode, architecture, OS, and durability profile, then each workload's limits:
`workload_limits` for the conversation, managed, and foreign populations, and
`tasks_limits` and `scale_limits` for the two workloads below. The full run
writes `zig-out/bench-reports/loam.txt`.

After `--`, `--smoke` runs the small version that `check` runs and combines
with any filter. Pass at most one of these filters:

| Filter | Runs | Writes |
| --- | --- | --- |
| `--references-only` | only the returned-authority, held-facet and parked-call phases, across the same managed populations and ancestry depths | `loam-references.txt` |
| `--managed-only` | the complete managed population, its workers and foreign fields | `loam-managed.txt` |
| `--foreign-only` | only the foreign fields | `loam-foreign.txt` |
| `--ordinary-only` | only the conversation graph, whose rows the performance page charts | `loam-ordinary.txt` |
| `--tasks-only` | only the Tasks board phases below, on each disk engine | `loam-tasks.txt` |
| `--scale-only` | only the cold-read scale populations below, with 10 thousand and 1 million stored resources | `loam-scale.txt` |
| `--collection-only` | only the collection counts below | stdout |

Filtered reports land in `zig-out/bench-reports/`. With `--tasks-only`,
`--engine=lmdb` or `--engine=sqlite` runs the board on that engine alone.
The bench refuses `--engine` with any other filter.

For a Linux Tasks engine comparison, pin both runs to the same allowed logical
CPU with `--cpu`, for example `--tasks-only --cpu=5`. The report names the CPU.
Choose an available CPU on your machine with `lscpu -e=CPU,MAXMHZ`. This matters
on machines with different CPU types: a migration can change even a hot read
that never reaches either engine. An unavailable CPU is refused, and `--cpu`
requires `--tasks-only`. Pinning does not fix clock frequency, competing load,
or disk variation, so repeat both engines on the same CPU.

Record the backing filesystem and transaction count with a comparison. When
CPU profiles do not explain a durable-write gap, isolate storage waits with
syscall tracing and a separate tmpfs control before attributing it to wrapper
work. A tmpfs result measures execution without persistent-device waits.
For upstream benchmarks, check whether the timed completion waits for durable
storage and whether the wrapper combines writes into fewer transactions.

## Tasks workload

The [Tasks app](../../apps/tasks/README.md) is a second application on Loam.
[`tasks.zig`](tasks.zig) opens the app's own `Storage` (a disk engine, the
attachment and the board behaviors) and drives it with hosted calls through the Host's local
owning call, the same one the app uses at startup. No socket is involved, and
nothing of the board is reimplemented here. A full run fills one board with 16
lists of 256 tasks. The last list stops 64 tasks short so that moves and
watched adds have room.

| Phase | Operation | Checked in smoke |
| --- | --- | --- |
| `add` | one `mutate` that adds a task and replies with its capability | one commit per add |
| `hot-read` | `text` on four warmed tasks | zero backend reads |
| `cold-read` | the cache is evicted, then `list`, `task` and `text` | reads per chain stay under a fixed ceiling |
| `move` | a task moves to another list and back, named by capability | one commit per move |
| `share` | `derive` of a read-only object share of a task | one commit per share |
| `share-read` | `text` through that share | the shared task's text |
| `watch` | after each add, the board's receiver is polled with the last cursor | each poll reports a change, one commit per add |

Each row names its engine and reports operations, backend reads and commits,
allocations, the most reads one operation needed, elapsed time and p50, p95
and p99 latency. A `tasks_store` line follows each engine's run with the bytes
its files hold after the store closes.
Eviction before a cold chain is outside its latency sample. The ceiling on
cold reads does not depend on how full the board is, because a chain loads
only the board, one list and one task with their authority records. The
smoke run uses two lists of eight tasks.

## Cold reads at scale

`zig build bench-loam -Doptimize=ReleaseFast -- --scale-only` stores 10 thousand
and then 1 million resources under one owner and measures a cold hosted read of
a few of them. The unfiltered full run leaves it out because the 1 million
population takes minutes to build. The unfiltered `--smoke` run, which `check`
runs, and `--smoke --scale-only` use 1,024 and 8,192 resources and 16 samples
and keep every check below.

[`scale.zig`](scale.zig) reuses the managed Store, Host and trusted setup. One
owner holds every resource, because owner directory pages grow with the count
and one owner is the hardest case for a full-store scan. Setup stages 16
resource appends and their content records per commit through
`managed_setup.zig`. A commit retains one change batch and each append is one of
its effects, so `ChangeBatchRecord.max_effects` bounds the batch. A sampled
resource keeps its resource and content ids, and 128 samples (16 in smoke) are
drawn uniformly from the whole population by a fixed seed. Only the samples are
granted a use and control endpoint, so heap and actors do not scale with the
count.

The Loam record cache is 512 slots of 64 KiB, a resident budget of 32 MiB, and
`scale_limits` prints every Store limit. LMDB's page cache and the OS file cache are separate
from Loam's record cache. The run does not drop OS caches, so cold means evicted from Loam's
record cache. For each sample the cache is evicted outside the latency sample, then one
hosted `read` goes through the sample's held use endpoint. The cache charges
each resident record its encoded size, so `max_resident_charge_bytes` follows
`encoded_bytes`, the length the backend returned.

| Line | Reports |
| --- | --- |
| `scale_limits` | population, sample count, seed, batch, Store limits, LMDB map |
| `scale_setup` | populate and share time, commits, database bytes, objects, heap with a warm cache, actors |
| `scale_cold` | backend reads and encoded bytes per call (min, max, mean), p50, p95 and p99 latency, resident charge, heap before and after, actors, RSS, major and minor fault deltas |

Each read is one backend read batch. `process_memory` lines before and after
the phase hold the same RSS and fault counts, and the fault deltas cover the
whole process.

Every run fails unless each reply is the expected value, no cold call commits
or leaves residency above the budget, setup creates no actor, and the actor
count after the phase equals the count after sharing. Actor counts must also
match across populations. The larger population may add at
most two reads to a cold call. The resource index has four fixed levels, and
the sampled path shares its root and level-1 pages with the path the call also
reads to the owner's parent resource while slots stay below 2^24, so only the
lower two pages can differ. A scan would add reads in proportion to the count.

## Collection cost

`zig build bench-loam -Doptimize=ReleaseFast -- --collection-only` uses the
Volatile backend with two cache slots and 1,024-byte record scratch. Each row
starts with the same rooted chain of 1,024 records and 256 unreachable records
in two-record cycles. Holds vary across 0, 32 and 128 distinct already-reachable
objects. Batch work limits vary across 8, 64 and 256. Setup is outside counting.
The ordinary `--smoke` profile also runs this matrix with a 128-record chain,
64 garbage records and 0, 8 or 32 holds under `check`.

Submitted root IDs come from actual batches. Hash bytes are derived as two
33-byte key inputs per submitted ID: preparation and backend fingerprinting on
the successful path. Predicted seed-mark lookups count submitted roots in phases
that seed, and pre-batch marked seeds inspect those marks before the commit.
These are root-origin counts, not every backend lookup.

Trace counts use committed queue-head advances. Commit and foreground-fence counts
are actual batches. The Store allocator counts successful raw preparation
allocations and record-sized scratch allocations, excluding resize and remap
calls.

Every row verifies exact survivors and reclaimed records, one trace per reachable
record, one submission per unchanged held root, one scratch allocation per cycle
and the block on new work while a batch is outstanding. These are cost and
correctness budgets. Volatile commits provide no durability and its hash-table
cursors cost differently from LMDB's, so the profile measures no timing, fsync
throughput or power-loss behavior. The collection tests cover restart
clearing, late holds and recovery.

## LMDB populations

Each population holds conversation headers with <!-- value workload.zig messages_per_conversation -->4<!-- /value --> message records per
conversation, and every report line names its conversation count and message
size. Headers are rooted actors holding strong references to their latest
messages. Each message has a strong previous-message reference and a weak
conversation reference. Messages have no actor endpoints and stay outside the
record cache during calls. An edit increments a header version without changing
its message chain.

The workload is shaped like Rooms but is not the Rooms application. A separate
managed population exercises grants over the same Host/Vat and LMDB interfaces.
It also measures Zig-level observation contexts, replay fanout, bounded owner
retirement, returned capabilities and eight parked calls. A byte-fed witness
session supports owning local Host Value calls, and measured application calls
stay local. Neither population exercises search, Rust or the C ABI. Separate
foreign-field phases use two Zig-level stores and byte-fed sessions to measure
restoration without socket latency.

## Managed population

Each managed run creates a population of resources under one owner and
compares a shallow and a deeper resource and grant ancestry. The owner grants
subtree access to a Zig-level use reference. That reference delegates a distinct
grant for each resource, bound to hosted use and separately retained control
endpoints.

The [managed workload](managed.zig) declares the cache, pinned-record, call,
lease and endpoint limits, and derives its collection journal quota from
the records initially kept and cached plus the cold call calibration window.
Directory pages are outside the pinned-model budget, so the bound includes
their traversal, endpoint/descriptor/header/content reads, newly restored
retentions and each portrait's strong edges. Schema edge limits and directory
level types supply the bound. Journal allocation grows only with actual debt.

Calibration serializes read-only calls to one endpoint and finishes collection
before further calls, so the quota allows no unlimited churn between batches.
Default Store limits are independent of this benchmark population. Output
records the population, ancestry, cache, call and pending-byte limits.

Creation samples include the resource append and content commit. Sharing samples
include Zig-level authority evaluation and atomic grant, use/control descriptors
and endpoint creation. Content is installed beforehand. These samples measure
the Zig-level issuer. Hosted derivation/publication costs remain separate.

Managed calls use the existing durable Host adapter. The phases are:

- **Control attenuation:** a chain of narrowed controls (four links in smoke, 32
  in the full workload). Each step evicts the cache, checks current management
  ancestry and persists one narrowed descriptor and one retained change batch.
  The final control is revoked while its resource use stays active. Reports
  include retained records, bytes and management depth.
- **Hot reads:** 128 calls across four warmed resources.
- **Cold reads:** the whole managed record cache is evicted before each call.
  Latency excludes eviction, and elapsed phase time includes it.
- **Cache pressure:** 128 reads across the population, with the shared owner
  and directory pages competing with endpoints, descriptors and content.
- **Unrelated edits:** 128 groups of one content edit and three sibling reads
  through the receipt wrapper. Each edit commits once and sibling content stays
  loaded. Only the first edit may load the history root, so later edits and
  warmed sibling reads need no backend reads. Output separates mutation reads
  from sibling reads.
- **Revocation:** up to 128 groups revoke a distinct grant, refuse a read and
  an edit through its held use endpoint, and read an unrevoked sibling where
  one remains. Each group commits one grant mutation and event.

Before control and mutation phases, a resource stores a strong self-reference
inside its object-scoped grant. The reference and facet phases then run:

- **Reference phases:** exact and dependent returns followed by a call, with
  128 groups in a full run and eight in smoke. A final normal actor call
  retires released facet boxes before their count is checked and is included in
  the phase call counts. Each latency sample covers the two-call group.
- **Facet survival:** eight separately retained facets survive 32 collection
  rounds (four in smoke). Eviction leaves zero resident record bytes and
  exactly eight facets.
- **Cold parked:** fills the attachment's call window through one facet. It
  verifies one coalesced read, the admitted call storage, refusal of one call
  past the window and completion of all accepted calls.
- **Retention:** 8, 32 and 128 independent facets held across up to 128
  resources for 32 collection rounds (8 and 16 facets for four rounds in
  smoke). Every held facet stays callable, eviction leaves zero resident record
  bytes, and heap use is unchanged after the first round. Reports separate the
  capacity cost of capability slot-array growth from the whole retained heap
  delta. The remaining increase has a 1 KiB allowance per holder for two
  retained authorities, actor state and other Host/Vat index growth.

Reports separate retained Zig bytes from whole-process memory. They include
reads, commits, allocations, call throughput and latency for a complete
collection-and-call round. Setup contributes to aggregate counts and elapsed
time, and the final call that retires released boxes lies outside this row.

After those phases, leaf resources move into a sibling container and back with
fresh Zig-level admission for each act. Eight pairs run in smoke and 128 in the
full workload. Each cold pair must stay within a fixed ancestry/index read
budget independent of population. A child cursor then visits the entire admitted
population with bounded model residency, and its items and read budget are
checked. These measure Zig-level moves and queries. The CapTP/LMDB tests establish
hosted structural effects and exact retries.

Retirement runs last. It traces expired history first, publishes up to 32
managed use endpoints, then runs a sweep and full owner retirement through
ordinary hosted calls. Every step starts with an evicted cache and prepares one
bounded index and authority path.

Collection after each phase separates committed cleanup from physical
reclamation. Aggregate elapsed time, reads, commits and allocations include
collection, and step latency and maximum reads exclude it. Output records steps,
backend reads and commits, allocations, maximum reads for one step, remaining
records/bytes, heap and process memory. Latency samples every sixteenth step.
There are no wall-clock limits.

The workload verifies immutable name-index entries and reports 58 logical bytes per
name reservation, excluding backend overhead. Held resource endpoints and the
Zig-level issuer preserve terminal refusal records until teardown. The volatile and
LMDB churn proofs separately check 32 create/share/revoke/delete cycles, stable
record counts after journal saturation, bounded payload bytes, delegation quota
reuse and monotonically increasing allocation floors.

Reports include operations, groups, backend reads, commits, allocations,
retained Zig bytes, cache bytes, elapsed time, local operations per second and
group latency percentiles. Operations count resources for creation/sharing and
calls for the hosted phases. Creation and sharing sample every resource, and
call phases sample 128 operations or groups.

The smoke run uses 16 resources and eight call groups for both ancestry shapes.
It validates replies, zero reloads on warmed reads and unrelated edits, commit
counts, revocation refusal, cold loading, bounded retained history, and complete
Zig allocation release. Cold reads have a population-independent ceiling of 16
plus two reads per additional ancestor for this graph and its four-resource
sampled working set.

## Measurements

- **Footprint:** encoded stored bytes, object count, resident record buffers,
  and outstanding Zig allocations after all headers have callable endpoints
  and their records have been evicted. The Zig heap figure includes reserved
  attachment tables, Host/Vat state, and the workload's capability/ID arrays.
  It excludes LMDB's cache and other C allocations, allocator overhead, and RSS.
- **Hot reads:** repeated calls across eight resident conversation headers.
- **Cold reads:** explicit eviction before each call. The per-call samples
  exclude eviction. Elapsed workload time includes it. Cold means absent from
  Loam's cache, not necessarily absent from the OS page cache or physical disk.
- **Cache pressure:** reads across more headers than the <!-- value workload.zig cache_slots -->16<!-- /value --> cache slots.
  Each full phase samples 128 operations. This is not a full-population scan.
- **Unrelated edits:** 128 rounds of one durable header edit followed by seven
  reads of other headers. Each latency sample covers all eight calls. Backend
  reads expose unnecessary invalidation separately from commit latency.
- **Edits:** 128 durable edits of one resident header. Each sample is one call
  and one synchronous LMDB commit, so it measures commit cost.
- **Wakeup bursts:** sixteen bursts of up to 64 calls, either to one cold
  header or to distinct cold headers. Latencies cover entire bursts, including
  admission and settlement. Read counts expose activation coalescing.
- **Collection:** unreachable pairs of draft records form cycles. Each batch
  admits a foreground read while the collection fence is held, verifies that
  it waits, commits, then settles that read. Reports include collected objects,
  batches, backend reloads, maximum fence and foreground service times, and
  extra Zig bytes observed immediately after collection preparation.
- **Restart:** after the run closes the database, a new Store, Host and
  Attachment reopen it, restore one conversation and call it. The time covers
  opening LMDB, which durably records that the store opened again, through the answer.
  The reply must include every committed edit, and the read count shows that
  only the called record loads.
- **Physical storage:** LMDB file capacity, allocated page high water, current
  record-tree pages, and entry counts before and after collection. High water
  is also sampled after each collection batch, outside its foreground latency
  sample. It includes reusable free pages and is not RSS or disk write volume.

LMDB uses its default synchronous commits. The service phases above execute
backend work synchronously outside actor turns. Collection samples use 64 and
256 record/phase steps per batch. Root seeding is additional work.

## Sustained worker executor

A separate conversation population uses the persistent workers in
[`worker_pool.zig`](worker_pool.zig), with bounded admission, cache and
pending-call limits that [`sustained.zig`](sustained.zig) checks. During these phases, only worker threads execute database reads and
commits, each through `hosting.Worker.run`. The owner thread drives Host/Vat,
prepares batches and installs completions.

Posting a request lends its buffer to one thread, and the completion event
hands it back after its I/O finishes. Workers wait on events between
requests. Shutdown waits for outstanding work, installs its completions, then
stops and joins all workers before releasing attachment or Store state. Worker
startup precedes borrowing any Store request, and a partial startup failure
stops and joins every worker it created.

Each read and mixed phase admits 1,024 calls, replacing settled calls immediately.
The mixed phase edits every eighth header and reads the others. Reports include
backend operations, allocations, per-call p50/p99 latency, throughput, maximum
occupied workers, turns at worker capacity and peak pending bytes.

This is a closed-loop load: offered traffic slows when the eight-call window
fills. It measures this bounded working set, not an open-loop arrival rate or
maximum throughput. Concurrent commits can invalidate an in-flight read
snapshot, and retries appear in the backend read counts. The owner polls worker
completions, and idle polling cost is part of these measurements.

Collection runs Zig-level commits on the same executor with 64 and 256 steps per
batch. Each batch sends both a transient foreground actor call and a durable
header read. Separate distributions expose unrelated Vat progress and the
stored call's collection fence. Replies and exact collection totals are checked.
The measured phases add no artificial disk delay.

Smoke uses sixteen conversations and 64 sustained calls per phase.
Calibration first limits worker concurrency to two workers and verifies that
a refused four-worker startup joins the partial pool. Next it holds four
actual cold-read workers to check refusal of a fifth request. It
then holds a collection commit, admits 65 durable calls, verifies refusal of
one excess call at the attachment's 64-call bound, and verifies that a transient
actor finishes while the accepted durable calls remain fenced.

Gates release and worker work completes before borrowed memory is freed,
including error cleanup. Workers join before pool or backend teardown.
Calibration completes its tracing cycle before adding measured garbage. The
smoke artifact uses its build-owned deadline to detect stalls, and elapsed
measurements have no acceptance threshold.

## Managed workers and foreign restoration

A separate managed population uses the same <!-- value worker_pool.zig capacity -->4<!-- /value -->-worker pool and <!-- value managed.zig max_calls -->8<!-- /value -->-call
window as ordinary actors. Only pool workers perform reads and commits.
Host/Vat installs completions on its owner thread.

Each read and mixed phase admits 1,024 calls across the population, with edits every eighth admission.
Each resource has at most one outstanding call, and every reply must equal
its exact expected content version. The mixed phase commits exactly 128 edits.
Smoke admits 64 calls and eight edits. Worker and pending-byte bounds, complete
allocation release and receipt sequences are checked.

Calibration holds a Zig-level collection commit, admits eight managed calls and
requires refusal of the ninth. A transient actor must complete while the
accepted calls remain fenced. Cleanup opens the gate and joins workers before
releasing borrowed buffers. This checks overload at the declared window
deterministically and does not measure an arrival rate. A 64-lease profile refuses
deeper concurrent preparations with `LeaseCapacity`, so the 258-lease budget
derives from the admitted record capacity.

After joining workers and retiring the Store, offline compaction reports elapsed time and
physical pages before and after replacement. Reopening must preserve every
metadata field except the open counter, which must move forward, and keep the entry count.

Foreign phases install checked URI recipes in managed content through a Save
that verifies the actual held target. A distinct Zig-level Store hosts 32 ordinary
durable conversation actors with rooted publication names. Smoke uses four.
Source populations and ancestry match the managed workload. Startup snapshots
include both Hosts, endpoint tables, the on-demand name factory and field
metadata. Publications and their targets belong to the target Store.

Each row runs 128 return-and-call groups, or eight in smoke. Both stores evict
records before each group. Established sessions retain registered names.
Fresh-session groups retire both previous shells, remove the selected volatile
name registration, and perform a new handshake and one Zig-level name-index lookup.
The rooted publication remains unchanged.

Exact returns and dependent facets
both call the target and check zero-valued content. Dependent calls also check
the current source grant through its normal forwarding path. Reports separate
source reads, target reads, name lookups, frames, bytes and allocation counts.
The source permits 17 plus two reads per added ancestor for a group. The target
permits one content read and, for a fresh name, one publication read.

Throughput includes one final local cleanup call, and group latency excludes
it. Cleanup reads have their own counter. Fresh group timing, allocation
counts and frame counts include session retirement and the new handshake.
The operations are real CapTP and storage operations over fed bytes. They
exclude socket delay, transport authentication, process startup and hardware
cold-cache behavior.
Cold process restoration, authority-role preservation and unavailable targets
have separate owning tests in the [reference guide](../../docs/loam/references.md).

Actor retirement can release a remote capability while the Vat is
opening another turn. A calibrated regression checks queued actor turns and
synchronous near calls: execution includes destructor cleanup, top-level Host
reentry refuses, and queued GC is pumped after the outer boundary returns.
The frame commits its running hold before destructors can resize the actor index.

## Process memory

OS snapshots accompany ordinary footprints and physical-storage phases,
managed creation/sharing/call phases, and sustained execution and collection.
`rss_bytes` includes resident code, stacks, allocator overhead, LMDB engine
allocations and resident mapped pages. `virtual_bytes` is whole-process mapped
address space, including unresident reservations. Both differ from tracked
workload Zig allocations, Loam record-cache bytes, encoded data, LMDB's configured
map and physical page high water. Each keeps its own field.

Linux reads RSS from `/proc/self/smaps_rollup` and virtual size from `statm`,
because the [`statm` resident counter](https://man7.org/linux/man-pages/man5/proc_pid_statm.5.html)
is approximate. macOS uses [Mach task information](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/task_info.h)
for current and maximum resident size and is unverified here.

[getrusage](https://man7.org/linux/man-pages/man2/getrusage.2.html) supplies
Linux process-lifetime peak RSS and both platforms' minor/major faults.
These include every thread and previous population in the same invocation, so
they are not population-local peaks or phase fault deltas. Linux peak
accounting can lag precise rollup RSS, so the reported peak may not exceed each
snapshot. Sampling occurs outside timed call groups, adds a small accounting
cost, and does not measure a phase's transient peak.

The workload heap counter excludes the worker executor's own allocations.
Process RSS includes them. No memory snapshot is a live CapTP session footprint.

## Reading the results

Read and allocation counts depend only on the code. Wall-clock results depend
on the machine, filesystem, and competing work. Repeat runs on the same system
before drawing timing conclusions. Record the revision and command with each
saved report.

All paths validate replies, collection totals, and complete Zig allocation
release. Hot reads and edits must cause no reloads, and same-target cold bursts
must coalesce to one load. The smoke run holds these structural costs with no
timing ceiling. It sets no throughput target and tests no capability authority.

[Order of work](../../docs/loam/architecture.md#order-of-work)
says what must pass before bindings. The measured profiles declare their working
sets and admission limits, and calibration proves refusal beyond those limits
and progress of unrelated actors. Keep these costs separate from the 500,000
live CapTP session target.

## Recorded results

[Recorded results](results.md) and
[managed access results](managed-results.md) hold the measured profiles,
environments, revisions, and limitations for each run.
