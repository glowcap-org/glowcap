# Loam LMDB workload

Run `zig build bench-loam -Doptimize=ReleaseFast` to measure the shipped Host/Vat,
record-backed actors, and LMDB backend together. Output names the optimization
mode, architecture, cache limits, cache-slot metadata bytes, and durability profile. The full run writes
`zig-out/bench-reports/loam.txt`. `-- --smoke` runs a small version under `check`.
Use `-- --references-only` to isolate the returned-authority, held-facet and
parked-call phases across the same managed populations and ancestry depths.
That run writes `zig-out/bench-reports/loam-references.txt`.
`-- --managed-only` runs the complete managed population, its native workers
and foreign fields, writing `zig-out/bench-reports/loam-managed.txt`.
`-- --foreign-only` isolates foreign fields in
`zig-out/bench-reports/loam-foreign.txt`. `-- --ordinary-only` runs only the
conversation graph, whose rows the performance page charts, writing
`zig-out/bench-reports/loam-ordinary.txt`. `-- --collection-only` isolates the
collection custody counts below and prints to stdout. Select at most one filter.

## Collection custody cost

`zig build bench-loam -Doptimize=ReleaseFast -- --collection-only` uses the
Volatile backend with two cache slots and 1,024-byte record scratch. Each row
starts with the same rooted chain of 1,024 records and 256 unreachable records
in two-record cycles. Holds vary across 0, 32 and 128 distinct already-reachable
objects; batch work limits vary across 8, 64 and 256. Setup is outside counting.
The ordinary `--smoke` profile also runs this matrix with a 128-record chain,
64 garbage records and 0, 8 or 32 holds under `check`.

Submitted root IDs come from actual batches. Hash bytes are derived as two
33-byte key inputs per submitted ID: preparation and backend fingerprinting on
the successful path. Predicted seed-mark lookups count submitted roots in phases
that seed; pre-batch marked seeds inspect those marks before the commit. These
are root-origin counts, not instrumentation of every backend lookup. Trace
counts use committed queue-head advances. Commit and foreground-fence counts
are actual batches. The Store allocator counts successful raw preparation
allocations and record-sized scratch allocations; resize/remap calls are excluded
from this count. The fixed fixture makes the scratch count unambiguous.

Every row verifies exact survivors and reclaimed records, one trace per reachable
record, one submission per unchanged held root, one scratch allocation per cycle
and the admission fence while a batch is outstanding. These are cost and
correctness budgets. Volatile commits provide no durability, and its hash-table
cursors have different costs from LMDB. This profile measures no timing,
fsync throughput or power-loss behavior. Restart clearing, late custody and
recovery are covered by the owning collection scenarios.

## LMDB populations

Each population contains 64, 512, or 2,048 conversation headers, with four
message records per conversation. Headers are rooted actors holding strong
references to their latest messages. Each message has a strong previous-message
reference and a weak conversation reference. Messages contain 256 or 4,096 bytes.
They have no actor endpoints and remain outside the record cache during calls.
An edit increments a header version without changing its message chain.

This is a workload shaped like Rooms, not the Rooms application. A separate
managed population exercises grants over the same Host/Vat and LMDB interfaces.
The managed population also measures native observation contexts, replay
fanout, bounded owner retirement, returned capabilities and eight parked calls.
A byte-fed witness session supports owning local Host Value calls; measured
application calls stay local. Neither population exercises search, Rust or the C ABI. Separate foreign-field
phases use two native stores and byte-fed sessions to measure restoration
without socket latency.

## Managed population

Each managed run creates 64, 512, or 2,048 resources with 128-byte content
records under one owner. It compares zero and four additional resource and
grant ancestors. The owner grants subtree access to a native use reference.
That reference delegates a distinct grant for each resource, bound to hosted
use and separately retained control endpoints. The managed cache has 64 slots
and a 4 MiB resident limit; each operation can pin 32 model records.
The attachment admits eight 4 KiB calls, with 32 KiB pending storage and
512-byte forwarded replies. It reserves 258 leases: eight 32-record
preparations plus two native issuer slots. Its endpoint budget allows two
endpoints per resource plus one trusted owner administration endpoint.
The [managed workload](managed.zig) derives its collection journal quota from
initial retention/cache custody plus the cold eight-call calibration window.
Directory pages are outside the pinned-model budget, so the bound includes
their traversal, endpoint/descriptor/header/content reads, newly restored
retentions and each portrait's strong edges. Schema edge limits and directory
level types supply the bound; journal allocation grows only with actual debt.
Calibration serializes read-only calls to one endpoint and finishes collection
before further calls. The quota does not guarantee unlimited churn between
batches. Default Store limits remain independent of this benchmark population.
Output records the population, ancestry, cache, call and pending-byte limits.

Creation samples include the resource append and content commit. Sharing samples
include native authority evaluation and atomic grant, use/control descriptors
and endpoint creation. Content is installed beforehand. These samples measure
native issuer custody; hosted derivation/publication costs remain separate.

Managed calls use the existing durable Host adapter:

- **Control attenuation:** four links in smoke and 32 in the full workload.
  Each step evicts the cache, checks current management ancestry and persists
  one narrowed descriptor and one retained change batch. The final control is independently revoked while
  its resource use remains active. Reports include retained records, bytes and
  management depth; reader residency remains bounded independently of the chain.
- **Hot reads:** 128 calls across four warmed resources.
- **Cold reads:** eviction of the entire managed record cache before each call.
  Latency excludes eviction, and elapsed phase time includes it.
- **Cache pressure:** 128 reads across the population, with its shared owner
  and directory pages competing with endpoints, descriptors and content.
- **Unrelated edits:** 128 groups of one content edit and three sibling reads.
  Each group uses the receipt wrapper, must commit once and preserve sibling
  content without reloading. The first edit may load the history root once;
  later edits and all warmed sibling reads require no backend reads. Output
  separates mutation reads from sibling reads. The existing 4 KiB call arena
  still bounds each call.
- **Revocation:** up to 128 groups revoke a distinct grant, refuse both read
  and edit through its held use endpoint, and read an unrevoked sibling where
  one remains. Each group must commit one grant mutation and event.

Before control and mutation phases, a resource stores a strong self-reference
inside its object-scoped grant. The reference phases measure exact and dependent
returns followed by a call, with 128 groups in a full run and eight in smoke.
A final normal actor call retires released facet boxes before checking their
count. Phase call counts include that call; each latency sample covers the
two-call group.
Eight separately retained facets then survive 32 collection rounds (four in
smoke). Eviction must leave zero resident record bytes and exactly eight facets.
The cold parked phase admits eight calls through one facet, with 4 KiB per call
and 512 reply bytes per owned Host operation. It verifies one coalesced read,
32 KiB of admitted call storage, refusal of a ninth call and completion of all
accepted calls. Reports separate retained Zig bytes from whole-process memory.
Additional retention phases hold 8, 32 and 128 independent facets across up to
128 distinct resources for 32 collection rounds. Smoke holds 8 and 16 facets
for four rounds. Every held facet remains callable, eviction leaves zero
resident record bytes, and heap use must remain unchanged after the first
round. Reports separate the exact capacity cost of capability slot-array
growth from the whole retained heap delta. The remaining increase has a 1 KiB
allowance per holder for two retained authorities, actor state and other
Host/Vat index growth. The whole-population slot array can cross a capacity
threshold when holders are added; its cost remains in the reported heap. Reports include
reads, commits, allocations, call throughput and latency for a complete
collection-and-call round. Setup contributes to aggregate counts and elapsed
time; the final call that retires released boxes lies outside this row.

After those phases, leaf resources move into a sibling container and back with
fresh native admission for each act. Eight pairs run in smoke and 128 in the
full workload. Each cold pair must stay within a fixed ancestry/index read
budget independent of population. A child cursor then visits the entire admitted
population with bounded model residency. Its items and read budget are checked.
These measure native moves and queries; the CapTP/LMDB tests establish hosted
structural effects and exact retries.

Retirement runs last. It traces expired history first, publishes up to 32 managed
use endpoints, then runs a sweep and full owner retirement through ordinary
hosted calls. Every step starts with an evicted cache and prepares one bounded
index and authority path. Collection after each phase separates committed
cleanup from physical reclamation. Aggregate elapsed time, reads, commits and
allocations include collection; step latency and maximum reads exclude it.
Output records steps, backend reads and
commits, allocations, maximum reads for one step, remaining records/bytes, heap
and process memory. Latency samples every sixteenth step; wall-clock limits are
absent. The workload verifies immutable name-index entries and reports 58
logical bytes per name reservation, excluding backend overhead. Held resource
endpoints and the native issuer preserve terminal refusal records until teardown.
The volatile and LMDB churn proofs separately check 32 create/share/revoke/delete
cycles, stable record counts after journal saturation, bounded payload bytes,
delegation quota reuse and monotonically increasing allocation floors.

Reports include operations, groups, backend reads, commits, allocations, retained Zig
bytes, cache bytes, elapsed time, local operations per second and group latency
percentiles. Operations count resources for creation/sharing and calls for the
hosted phases. Creation and sharing sample
every resource; call phases sample 128 operations or groups. The smoke run uses
16 resources and eight call groups for both ancestry shapes. It validates
replies, zero reloads on warmed reads and unrelated edits, commit counts,
revocation refusal, cold loading, bounded retained history, and complete Zig
allocation release.
Cold reads have a population-independent ceiling of 16 plus two reads per
additional ancestor for this graph and its four-resource sampled working set.
Wall-clock times have no pass/fail threshold.

## Measurements

- **Footprint:** encoded stored bytes, object count, resident record buffers,
  and outstanding Zig allocations after all headers have callable endpoints
  and their records have been evicted. The Zig heap figure includes reserved
  attachment tables, Host/Vat state, and the workload's capability/ID arrays.
  It excludes LMDB's C allocations, mapped pages, allocator overhead, and RSS.
- **Hot reads:** repeated calls across eight resident conversation headers.
- **Cold reads:** explicit eviction before each call. The per-call samples
  exclude eviction; elapsed workload time includes it. Cold means absent from
  Loam's cache, not necessarily absent from the OS page cache or physical disk.
- **Cache pressure:** reads across more headers than the sixteen cache slots.
  Each full phase samples 128 operations; this is not a full-population scan.
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
  opening LMDB, which durably records a new incarnation, through the answer.
  The reply must include every committed edit, and the read count shows that
  only the called record loads.
- **Physical storage:** native map size, allocated page high water, current
  record-tree pages, and entry counts before and after collection. High water
  is also sampled after each collection batch, outside its foreground latency
  sample. It includes reusable free pages and is not RSS or disk write volume.

LMDB uses its default synchronous commits. The service phases above execute
backend work synchronously outside actor turns. Collection samples use 64 and
256 record/phase steps per batch; root seeding is additional work.

## Sustained native executor

A separate conversation population uses four persistent native workers, an
eight-call admission window, sixteen cache slots and a 256 KiB pending-call
limit. During these phases,
only workers execute database reads and commits. The owner thread drives Host/Vat,
prepares batches and installs completions. Posting a request lends its buffer
to one worker; the completion event returns custody after native I/O finishes.
Workers wait on events between requests. Shutdown waits for outstanding work,
installs its completions, then stops and joins all workers before releasing
attachment or Store state. Worker startup precedes borrowing any Store request;
a partial startup failure stops and joins every worker it created.

Each read and mixed phase admits 1,024 calls, replacing settled calls immediately.
The mixed phase edits every eighth header and reads the others. Reports include
backend operations, allocations, per-call p50/p99 latency, throughput, maximum
occupied workers, turns at worker capacity and peak pending bytes. This is a
closed-loop load: offered traffic slows when the eight-call window fills. It
establishes this bounded working set, rather than an open-loop arrival-rate or
maximum throughput claim. Concurrent commits can invalidate an in-flight read
snapshot; retries appear in the backend read counts. The owner polls native completions; idle polling cost
is part of these measurements and is not a production scheduling recommendation.

Collection runs native commits on the same executor with 64 and 256 steps per
batch. Each batch sends both a transient foreground actor call and a durable
header read. Separate distributions expose unrelated Vat progress and the
stored call's collection fence. Replies and exact collection totals are checked.
The measured phases insert no artificial disk delay.

Smoke uses sixteen conversations and 64 sustained calls per phase.
Calibration first limits native concurrency to two workers and verifies that
a refused four-worker startup joins the partial pool. Next it holds four
actual cold-read workers to check refusal of a fifth request. It
then holds a collection commit, admits 65 durable calls, verifies refusal of
one excess call at the attachment's 64-call bound, and verifies that a transient
actor finishes while the accepted durable calls remain fenced. Gates release
and native work completes before borrowed memory is freed, including error
cleanup. Workers join before pool or backend teardown.
Calibration completes its tracing cycle before adding measured garbage.
The smoke artifact uses its build-owned deadline to detect stalls.
Elapsed measurements have no acceptance threshold.

## Managed workers and foreign restoration

A separate managed population uses the same four-worker pool and eight-call
window as ordinary actors. Only native workers perform reads and commits;
Host/Vat installs completions on its owner thread. Each read and mixed phase
admits 1,024 calls across the population, with edits every eighth admission.
Each resource has at most one outstanding call, and every reply must equal
its exact expected content version. The mixed phase commits exactly 128 edits.
Smoke admits 64 calls and eight edits. Worker and pending-byte bounds, complete
allocation release and receipt sequences are checked.

Calibration holds a native collection commit, admits eight managed calls and
requires refusal of the ninth. A transient actor must complete while the
accepted calls remain fenced. Cleanup opens the gate and joins workers before
releasing borrowed buffers. This is deterministic overload evidence for the
declared window, rather than an arrival-rate measurement. The initial 64-lease
profile refused deeper concurrent preparations with `LeaseCapacity`; the
258-lease budget derives from the admitted record capacity. After joining
workers and retiring the Store, offline compaction reports elapsed time and
physical pages before and after replacement. Reopening must preserve every
metadata field except the expected fresh incarnation and retain the entry count.

Foreign phases install checked URI recipes in managed content through a Save
that verifies the actual held target. A distinct native Store hosts 32 ordinary
durable conversation actors with rooted publication names; smoke uses four.
Source populations and ancestry match the managed workload. Startup snapshots
include both Hosts, endpoint tables, the on-demand name factory and field
metadata. Publications and target custody belong to the target Store.

Each row runs 128 return-and-call groups, or eight in smoke. Both stores evict
records before each group. Established sessions retain registered names;
fresh-session groups retire both previous shells, remove the selected volatile
name registration, and perform a new handshake and one native name-index lookup.
The rooted publication remains unchanged. Exact returns and dependent facets
both call the target and check zero-valued content. Dependent calls also check
the current source grant through its normal forwarding path. Reports separate
source reads, target reads, name lookups, frames, bytes and allocation counts.
The source permits 17 plus two reads per added ancestor for a group; the target
permits one content read and, for a fresh name, one publication read.

Throughput includes one final local cleanup call; group latency excludes it.
Cleanup reads have their own counter. Fresh group timing and allocation counts include session retirement and the
new handshake; frame counts include the new handshake. These are actual
CapTP and storage operations over fed bytes. They exclude socket delay,
transport authentication, process startup and hardware cold-cache behavior.
Cold process restoration, authority-role preservation and unavailable targets
have separate owning tests in the [reference guide](../../docs/loam/references.md).

Native actor retirement can release a remote capability while the Vat is
opening another turn. A calibrated regression checks queued native turns and
synchronous near calls: execution includes destructor cleanup, top-level Host
reentry refuses, and queued GC is pumped after the outer boundary returns.
The frame commits its running hold before destructors can resize the actor index.

## Process memory

OS snapshots accompany ordinary footprints and physical-storage phases,
managed creation/sharing/call phases, and sustained execution and collection.
`rss_bytes` includes resident code, stacks, allocator overhead, native engine
allocations and resident mapped pages. `virtual_bytes` is whole-process mapped
address space, including unresident reservations. Both differ from tracked
workload Zig allocations, Loam record-cache bytes, encoded data, LMDB's configured
map and physical page high water; each keeps its own field.

Linux reads RSS from `/proc/self/smaps_rollup` and virtual size from `statm`.
The [Linux memory interface](https://man7.org/linux/man-pages/man5/proc_pid_statm.5.html)
explains why the approximate `statm` resident counter is unsuitable here.
macOS uses [Mach task information](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/task_info.h)
for current and maximum resident size; its execution remains unverified here.
[getrusage](https://man7.org/linux/man-pages/man2/getrusage.2.html) supplies
Linux process-lifetime peak RSS and both platforms' minor/major faults.
These include every thread and previous population in the same invocation. These are not population-local
peaks or phase fault deltas. Linux peak accounting can lag precise rollup RSS;
the fields do not assert that the reported peak exceeds each snapshot.
Sampling occurs outside timed call groups; it adds
its own small accounting cost and does not measure a phase's transient peak.
The workload heap counter excludes the worker executor's own allocations;
process RSS includes them. No memory snapshot is a live CapTP session footprint.

## Reading the evidence

Read and allocation counts are structural evidence. Wall-clock results depend
on the machine, filesystem, and competing work. Repeat runs on the same system
before drawing timing conclusions. Record the revision and command with each
saved report. All paths validate replies, collection totals, and complete Zig
allocation release. Hot reads and edits must cause no reloads;
same-target cold bursts must coalesce to one load. The smoke run holds these
structural costs without imposing a machine-dependent timing ceiling. It does
not establish a throughput target or correctness of capability authority.

The [Loam readiness checkpoint](../../docs/planning/loam/architecture.md#readiness-before-the-c-abi)
owns acceptance before bindings. The measured profiles declare their working
sets and admission limits. Calibration proves refusal beyond those limits and
progress of unrelated actors; it does not establish an open-loop arrival-rate
or maximum throughput target. Keep those costs separate from the 500,000 live
CapTP session target.

## Recorded results

[Recorded results](results.md) preserve the measured profiles, environments,
revisions, and limitations for each run.
