# Loam workload results

These reports record measured workloads at their stated revisions.
[The workload guide](README.md) owns the runnable profiles and measurement
boundaries. Earlier reports keep their original scope and numbers.
[Managed access results](managed-results.md) are kept separately.

Older entries that name only the OS and architecture leave out the hardware
model, storage device, and CPU placement, so their timings say nothing about
the environment below or any other host.

## October 14 measurement environment

The October 14 Tasks comparisons ran on an NVIDIA DGX Spark with 20 logical
ARM CPUs: Cortex-X925 cores up to 3.9 GHz and Cortex-A725 cores up to
2.808 GHz. Linux reported about 121.7 GiB of RAM. The kernel was
`7.0.0-1019-nvidia` on aarch64, with 4,096-byte pages.

The executable ran in the Linux development container. Its database directory
was a direct ext4 bind mount on a Samsung `MZALC4T0HBL1-00B07` 4 TB NVMe
SSD, with ordered data journaling and write barriers. The journal batched
writes for at most 15 ms. The tmpfs runs below used `/dev/shm` instead.

The builds used Zig 0.17.0 and ReleaseFast. Each study states its CPU
placement, source revision, cache state, and sample count. The host was
shared, so pinning a CPU did not remove competing load or disk variation.

## Controlled CPU comparison, October 14, 2026

Both production engines ran the full Tasks workload in the
[recorded environment](#october-14-measurement-environment), three paired
runs pinned to logical CPU 5 (reported maximum 3.9 GHz). Both engines used
their existing synchronous durability settings. Each figure is the median of
the three runs' p50 values. The board, backend reads, commits, and tracked
Zig allocations matched across engines.

Cold reads evict Loam's record cache, and the OS page cache stays warm.

| Phase | LMDB p50 µs | SQLite p50 µs |
| --- | ---: | ---: |
| add | 3,097 | 1,740 |
| hot-read | 17.09 | 16.64 |
| cold-read | 137.02 | 206.43 |
| move | 3,095 | 1,809 |
| share | 2,700 | 1,601 |
| share-read | 25.20 | 29.65 |
| watch | 3,191 | 1,815 |

With CPU placement controlled, LMDB's cold chain is 34% faster and SQLite's
durable add is 44% faster. Hot reads call neither engine and come out nearly
equal. A control run pinned to CPU 0 put both hot reads near 37 µs and cold
reads at 240 µs on LMDB and 388 µs on SQLite. An unpinned run put LMDB hot
reads near 37 µs and SQLite hot reads near 17 µs.

So the older unpinned read comparison mixed CPU placement into its engine
figures. Placement does not explain the durable-write gap.

To reproduce on Linux, run `zig build bench-loam -Doptimize=ReleaseFast --
--tasks-only --cpu=5` with an allowed CPU on your machine, repeat both engines
on that same CPU, and keep the `tasks_cpu` report line. Pinning controls
placement, not clock frequency, competing load, or disk state. The first three
pairs ran the same executable under `taskset -c 5`, which pins the same way.

### Checked reads against stock LMDB

A diagnostic build compiled the pinned upstream `mdb.c` without forced
remapping or the checked-page patch, so it read through LMDB's own memory map.
Three runs used that build with the same CPU, board, and synchronous commits.
Its cold-read median was 133.02 µs against 137.02 µs for production checked
reads, so checked reads cost about 3% on that chain.

The stock build's add median was 3,163 µs, with run medians from 3,047 to
3,798 µs, so it did not change the durable-write result. This build is a
diagnostic baseline, not a supported profile, because a failed read through
its map ends the process.

Callgrind smoke runs used the baseline CPU target. The checked build executed
17,541,226 instructions for adds and 7,975,002 for cold reads, and stock LMDB
17,230,575 and 7,600,901, so checked reads added about 1.8% and 4.9%. SQLite
used about 19.6 million and 9.2 million, so production LMDB still used fewer
instructions.

Record CRC checks, Syrup validation, and copies led the self-cost ranking. The
generated LMDB C source accounted for 4.6% of the checked add phase. These are
CPU counts on a small board, not full-board latency or kernel I/O time.

The checked page cache adds anonymous mappings, whole-page `pread` copies on
misses, cache updates on writes, and metadata locking. Those costs are real,
but neither the older gap nor the stock baseline points to them for the
millisecond commit difference. LMDB flushes data before it writes metadata
through a synchronous descriptor (see its
[pinned commit code](https://github.com/LMDB/lmdb/blob/c279e0477c713076893e8c2b1a6337e421c15867/libraries/liblmdb/mdb.c)).
SQLite appends to and syncs its [WAL](https://www.sqlite.org/wal.html), and
spreads checkpoint work across commits and close. Both confirm a commit only
once it is durable, but they get there with different writes and waits.

### Filesystem control and other projects' results

The [recorded filesystem](#october-14-measurement-environment) is part of
these results, and the
[ext4 documentation](https://cdn.kernel.org/doc/html/latest/admin-guide/ext4.html)
describes its journal batching.

Three more pairs ran the same executable on CPU 5 with the working directory
on `/dev/shm`, a Linux tmpfs mount. Only the storage location changed. The
table again takes the median of each run's p50, in microseconds.

| Phase | LMDB on tmpfs | SQLite on tmpfs |
| --- | ---: | ---: |
| add | 397.89 | 418.53 |
| move | 568.29 | 589.23 |
| share | 347.49 | 371.27 |
| watch | 531.57 | 532.58 |
| cold-read | 136.38 | 206.54 |

Without a persistent device to wait on, LMDB narrowly wins the write phases,
and the read chain barely changes. That places LMDB's disk-write cost in the
storage path. A tmpfs run cannot show durable performance or separate device
flush time from filesystem work.

A full ext4 run traced file writes and syncs. LMDB issued 4,275 data syncs
and 4,275 metadata writes through its `O_DSYNC` descriptor, taking 7.784 and
5.090 seconds in total. SQLite issued 4,442 WAL syncs taking 5.147 seconds,
including WAL restarts and checkpoints. These counts include setup and
teardown, and tracing itself slows calls down.

A scratch run wrote and synced 32 MiB of zeros after LMDB set up its
metadata and before the workload started. A preload shim applied this only to
fresh benchmark files and checked that 33,554,432 bytes were allocated. Three
runs alternated this with ordinary file growth, using the same executable,
CPU, and durability flags. The median add p50 improved from 3,119 to
2,799 µs, about 10%.

So file growth explains part of the cost, but adds stay well above SQLite's
on disk. Preallocating also changes disk allocation and file size, so it is
not a default, and no engine code or open setting changed. The LMDB author's
[allocation discussion](https://www.openldap.org/lists/openldap-devel/201410/msg00008.html)
explains why reserving unwritten extents may still need filesystem metadata
work.

The older SQLightning result needs its original scope. Its
[`speedtest.tcl`](https://github.com/LMDB/sqlightning/blob/master/tool/speedtest.tcl)
does not turn on WAL and mixes single inserts with large transactions.
[LumoSQL](https://github.com/LumoSQL/lumosql#quickstart-using-the-build-and-benchmark-system),
its successor, reports a later run where SQLite's own storage engine beats
every LMDB variant it tested, and its maintainers say disk speed and data size
change the outcome.

[Mozilla's 2018 LMDB evaluation](https://mozilla.github.io/firefox-browser-architecture/text/0015-rkv.html#sqlite)
shows the same split on a different workload. Against SQLite in WAL mode, it
reports random reads at 1.070 µs for LMDB and 8.110 µs for SQLite, but
synchronous random writes at 166.412 µs and 82.125 µs. It is not a
controlled rerun of Tasks, but the same direction shows up outside glowcap.

Some fast LMDB wrappers also group transactions differently.
[`lmdb-js`](https://github.com/kriszyp/lmdb-js#dbputkey-value-options-promiseboolean)
batches asynchronous writes from the same event turn and resolves their
promises after commit. Its default `overlappingSync` mode outside Windows
resolves that promise before `db.flushed`, which waits for durability. Tasks
waits for one durable commit per hosted change, so a fair comparison matches
both the grouping and the event being timed.

### Flags and workload changes

`MDB_NOSYNC`, `MDB_NOMETASYNC`, and `MDB_MAPASYNC` change what survives a
crash, and none was enabled here. Forced remapping in the pinned source turns
off `MDB_WRITEMAP`, so adding that flag cannot bring back mapped writes
([pinned LMDB flags](https://github.com/LMDB/lmdb/blob/c279e0477c713076893e8c2b1a6337e421c15867/libraries/liblmdb/lmdb.h)).

A hosted change already writes its record, directory, permission, and receipt
changes in one transaction. Combining separately confirmed calls could spread
the cost of each flush, but it changes when transactions run and how long a
caller waits for confirmation, so no engine flag fixes it. These measurements
support LMDB's read and CPU advantage and SQLite's lower latency per durable
change. They do not make either engine the best choice for every
application.

## LMDB CPU and commit-failure study, October 14, 2026

This study used the [recorded environment](#october-14-measurement-environment).
The tree held the engine changes that refuse new work after
a commit with an unknown outcome. No durability flag was weakened and no upstream engine
source was changed.

The profiles and first timing pair preceded the SQLite failure-classification
fix below. Remaining timings include it. That fix changes failure handling,
not the successful commit protocol. These runs establish a comparison, not
a before-and-after performance improvement.

Three full Tasks runs per engine used
`zig build bench-loam -Doptimize=ReleaseFast -- --tasks-only --engine=<engine>`.
The first invocation ran both engines, LMDB then SQLite. The remaining order
was SQLite, LMDB, SQLite, LMDB. Values are medians of each run's percentiles.

| Phase | LMDB p50 µs | SQLite p50 µs | LMDB p99 µs | SQLite p99 µs |
| --- | ---: | ---: | ---: | ---: |
| add | 3,324 | 1,844 | 7,835 | 9,025 |
| hot-read | 37 | 17 | 41 | 19 |
| cold-read | 226 | 207 | 240 | 225 |
| move | 3,199 | 2,006 | 6,857 | 8,203 |
| share | 2,806 | 1,818 | 5,221 | 9,355 |
| share-read | 23 | 30 | 52 | 103 |
| watch | 3,301 | 1,965 | 6,789 | 8,904 |

Every phase kept the same backend reads, commits and Zig allocations across
engines. File sizes were 7,472,320 bytes for LMDB and 7,028,736 for SQLite.
The LMDB hot-read p50 was 17 µs in one run and 37 µs in two, although hot reads
call neither engine. Its cold-read p50 likewise ranged from 132 to 226 µs.
These variations prevent attributing every latency difference to an engine.
The higher SQLite p99 in this sample is not a general tail-latency guarantee.

### Where the work goes

`zig build profile-loam -- --smoke --tasks-only --engine=<engine>` measured
instructions under callgrind with the baseline CPU target. This is the small
board, not the full board in the timing table.

| Phase | LMDB instructions | SQLite instructions |
| --- | ---: | ---: |
| add | 17,209,928 | 19,586,803 |
| hot-read | 2,381,909 | 2,381,385 |
| cold-read | 7,581,343 | 9,245,855 |
| move | 18,138,311 | 19,966,745 |
| share | 7,916,607 | 9,094,635 |
| share-read | 978,986 | 1,036,674 |
| watch | 8,749,042 | 9,845,369 |

LMDB used about 12% fewer instructions for adds and 18% fewer for cold reads.
Record checksums, decoding and copies dominated both profiles. LMDB's own C
file accounted for 4% of add instructions, SQLite's for 15%. Reducing LMDB's
CPU overhead alone cannot explain away the observed millisecond commit gap.

A `strace -f -yy -tt -T -e trace=pwrite64,pwritev,fdatasync,fsync` run of the
first ReleaseFast executable with `--smoke --tasks-only` confirmed 33 LMDB data
flushes and 33 synchronous metadata writes, including setup. Metadata writes
used the separately opened `O_DSYNC` descriptor. SQLite synced its WAL, with
additional setup and checkpoint I/O. These are different durability protocols,
not equal flush counts. Trace timings are diagnostic and do not enter the table.

### Failure evidence and decision

`zig build loam-io-fault-test` runs both production engines under the same
Linux syscall fault matrix. It covers errors before and after writes or syncs,
short writes, and persistent errors through rollback. Each case exits without
closing the engine and checks the graph and reported outcome in a new process.
The case updates two cyclic records across multiple pages. Startup, compaction
and read failures are outside this matrix.

The harness exposed a SQLite adapter false refusal after an accepted WAL write
reported disk-full. Commit-time disk-full now remains uncertain and closes
admission until reopen. Both engines pass the matrix with these adapter changes.

LMDB retains a measured CPU advantage and a shared-read advantage here, but
has not displaced SQLite for synchronous per-operation commits. Batching may
amortize durability waits, at the cost of a different transaction or scheduling
contract. This study changes neither contract nor the default engine. It proves
neither power-loss recovery nor superiority under arbitrary page corruption.

## Tasks on LMDB and SQLite, October 14, 2026

These runs used Linux aarch64, Zig 0.17.0 and ReleaseFast through the
repository development front, on a shared machine, on October 14, 2026,
with the change that runs the Tasks workload on either disk engine. The
command is `zig build bench-loam -Doptimize=ReleaseFast -- --tasks-only
--engine=<engine>`, run three times per engine with the engines alternating.
Each figure is the median of those three runs.

Both engines use synchronous commits. LMDB flushes data with `fdatasync`
and writes metadata through an `O_DSYNC` descriptor. SQLite syncs the WAL.
They made the same backend reads and commits in every phase, and
the board was the same 16 lists of 256 tasks as above.

| Phase | Operations | Commits | LMDB p50 µs | SQLite p50 µs | LMDB p95 µs | SQLite p95 µs | LMDB p99 µs | SQLite p99 µs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| add | 4,032 | 4,032 | 3,308 | 1,903 | 6,203 | 3,188 | 7,122 | 6,102 |
| hot-read | 256 | 0 | 37 | 17 | 38 | 17 | 43 | 19 |
| cold-read | 256 | 0 | 228 | 207 | 234 | 214 | 239 | 228 |
| move | 128 | 128 | 3,120 | 1,900 | 5,624 | 2,889 | 6,019 | 6,516 |
| share | 32 | 32 | 2,898 | 1,588 | 3,902 | 2,207 | 5,512 | 2,302 |
| share-read | 32 | 0 | 23 | 30 | 39 | 38 | 56 | 97 |
| watch | 64 | 64 | 3,391 | 2,003 | 5,845 | 2,956 | 6,492 | 6,047 |

- **Commits.** SQLite took about 40 percent less time at p50 in every phase
  that commits, and about half at p95. At p99 the two were within 15 percent
  on add, move and watch.
- **Cold reads.** A 20-read chain was 9 percent faster on SQLite at p50. In
  two of eight SQLite runs and none of the LMDB runs, cold reads had a second
  mode near 400 µs that set p95.
- **Share reads.** Five reads took about 7 µs longer on SQLite at p50. The
  phase ran 6 percent more instructions under callgrind. The smoke run made
  about 700 more `fcntl` calls on SQLite, the locks it takes on its
  shared-memory index around each read transaction.
- **Hot reads** call neither engine. Their p50 was 37 µs in every LMDB run and
  in two SQLite runs, and 17 µs in the other SQLite runs.
- **Store size.** After the run, the closed store's files held 7.47 MB on LMDB
  and 7.03 MB on SQLite.

## Tasks, cold reads at scale and browser crossings, October 14, 2026

These runs used Linux aarch64, Zig 0.17.0, ReleaseFast and default synchronous
LMDB commits, through the repository development front, on a shared machine.
Each run passed every check its workload makes.

- The Tasks table is `zig build bench-loam -Doptimize=ReleaseFast -- --tasks-only`
  with the changes that profile the workload under callgrind,
  read a directory page in place, verify only the strong edges a commit
  introduces, and stop the Tasks pump once a pass changes nothing.
  `zig build profile-loam -- --tasks-only` attributes each phase, and the
  instruction count it reports fell between 46% and 64% per phase across those
  changes.
- The cold reads at scale are the same command with `--scale-only`, and the
  browser crossings are `zig build loam-browser-test`, both with the change that adds these workloads.

### Tasks

One board held 16 lists of 256 tasks, with the last list 64 tasks short.

| Phase | Operations | Backend reads | Commits | Most reads in one | p50 µs | p95 µs | p99 µs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| add | 4,032 | 48 | 4,032 | 3 | 3,418 | 6,689 | 7,793 |
| hot-read | 256 | 0 | 0 | 0 | 20 | 20 | 23 |
| cold-read | 256 | 5,361 | 0 | 21 | 139 | 142 | 146 |
| move | 128 | 395 | 128 | 14 | 3,507 | 6,298 | 7,060 |
| share | 32 | 68 | 32 | 6 | 3,101 | 4,630 | 5,604 |
| share-read | 32 | 160 | 0 | 5 | 26 | 29 | 54 |
| watch | 64 | 12 | 64 | 12 | 3,504 | 5,819 | 7,579 |

Every change commits once with a synchronous flush. The
[ordinary one-record edit](#ordinary-actor-baseline-october-9-2026) costs about
2.4 ms with the same flush. A cold chain read 20 or 21 records against a ceiling
of 24, the same as on the two-list smoke board.

### Cold reads at scale

One owner held every resource, with 128-byte content, and 128 seeded samples
held endpoints. The Loam record cache had 512 slots and 32 MiB. The OS page
cache stayed warm, so cold means evicted from Loam's cache only.

| Resources | Setup s | Setup commits | Tree MB | Reads per call | Bytes read per call | Cold p50 µs | Cold p99 µs | Heap after phase KB | Actors | Major faults |
| ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 10,000 | 4.4 | 625 | 8.1 | 16 to 17 | 29,989 | 106 | 116 | 383 | 257 | 0 |
| 1,000,000 | 490 | 62,500 | 808 | 17 to 18 | 47,960 | 157 | 175 | 394 | 257 | 0 |

A hundred times the resources added one read per call and no actors. The most
a call held resident was its own encoded bytes, 30,151 and 48,910. Setup commits
16 resources at a time because a commit holds at most that many changes for one
owner. At 1 million, RSS was 817 MB, nearly all LMDB's mapped pages from setup.

### Browser crossings

The browser proof created and shared one resource, reloaded the page, then
measured each operation through the shared reference.

| Operation | Transactions | JS calls | Callbacks | Rows read | Writes | Copied bytes |
| --- | --- | --- | --- | --- | --- | --- |
| Cold read (fetch the publication, then one call) | 18 | 20 | 75 | 38 | 2 | 10,355 |
| Warm read of the same resource | 0 | 0 | 0 | 0 | 0 | 0 |
| Edit the content | 2 | 10 | 57 | 53 | 8 | 20,949 |
| Replay the committed edit's receipt | 0 | 0 | 0 | 0 | 0 | 0 |
| Share (derive a reference) | 9 | 24 | 113 | 95 | 15 | 43,846 |

## Ordinary actor baseline, October 9, 2026

Two runs used Linux aarch64, Zig
`0.17.0-dev.2294+71403f299`, ReleaseFast and default synchronous LMDB commits.
The command was `zig build bench-loam -Doptimize=ReleaseFast -- --ordinary-only`,
through the repository development front. Both runs passed all six populations,
collection fences, exact reclamation, restart checks and final allocation release.

Each timing range below spans the two observed medians over 128 calls per run.
The machine was shared, so these ranges are not confidence intervals.

| Endpoints | Message bytes | Cold Zig heap bytes | Hot p50 ns | Cold p50 ns | Edit p50 ms |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 64 | 256 | 102,440 | 848 | 2,128–2,144 | 2.40–2.50 |
| 64 | 4,096 | 102,440 | 832–1,616 | 2,128–3,729 | 2.40–3.14 |
| 512 | 256 | 372,776 | 848 | 2,224–2,256 | 2.40 |
| 512 | 4,096 | 372,776 | 848–1,616 | 2,240–3,888 | 2.40–2.90 |
| 2,048 | 256 | 1,353,416 | 1,632–1,648 | 3,888 | 2.41–2.50 |
| 2,048 | 4,096 | 1,353,416 | 848–1,616 | 2,256–3,920 | 2.40–2.60 |

Both runs made zero backend reads for hot calls, one per cold call and zero
for unrelated-edit rounds. Hot calls allocated twice, cold calls three times
and edits five times. Each edit committed once. Sixteen same-target bursts
made sixteen backend reads, and each restart loaded one record. Cold heap
figures matched between runs and included no resident record buffers.

At 2,048 endpoints with 4,096-byte messages, collection used 673 batches at
64 steps and 169 batches at 256 steps. Maximum observed foreground delay was
6.89–8.09 ms and 8.80–9.82 ms respectively. These local synchronous workloads
exclude transport latency and managed grant evaluation. Their timing variation
shows no population-dependent dispatch cost and does not explain Rooms latency.

## Collection custody admission, October 4, 2026

Linux aarch64 ReleaseFast counts used `-- --collection-only`, a fixed rooted
chain of 1,024 records, 256 unreachable records and the Volatile backend.
Both runs measured Loam as of October 3, 2026. The changed source adds the
[cycle-owned custody journal](../../docs/decisions/adr/ADR-0050-transactional-reclamation.md),
which landed on October 4. Neither run measures LMDB or elapsed time.

| Held roots | Work limit | Commits, before / after | Submitted IDs, before / after | Root key hash bytes, before / after | Preparation allocations, before / after |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 8 | 577 / 577 | 0 / 0 | 0 / 0 | 577 / 1 |
| 0 | 64 | 73 / 73 | 0 / 0 | 0 / 0 | 73 / 1 |
| 0 | 256 | 19 / 19 | 0 / 0 | 0 / 0 | 19 / 1 |
| 32 | 8 | 577 / 577 | 18464 / 32 | 1218624 / 2112 | 1154 / 2 |
| 32 | 64 | 73 / 73 | 2336 / 32 | 154176 / 2112 | 146 / 2 |
| 32 | 256 | 19 / 19 | 608 / 32 | 40128 / 2112 | 38 / 2 |
| 128 | 8 | 577 / 577 | 73856 / 128 | 4874496 / 8448 | 1154 / 2 |
| 128 | 64 | 73 / 73 | 9344 / 128 | 616704 / 8448 | 146 / 2 |
| 128 | 256 | 19 / 19 | 2432 / 128 | 160512 / 8448 | 38 / 2 |

All rows trace 1,024 records and reclaim exactly 256. Scratch allocations fall
from one per batch to one per cycle. With 128 holds and eight-step batches,
predicted root-origin mark lookups fall from 57,472 to 128. Pre-batch marked
seeds fall from 57,344 to zero. Root IDs submitted during finishing in the
baseline add hash work but do not seed. The changed matrix seeds each held root
once regardless of batch count.

The [method](README.md#collection-cost)
owns the counter derivations and limits. The cost regression fails on the
baseline and passes on the journal implementation. The small matrix holds these
budgets under `check` with no timing thresholds.

## Checked residency and sparse edits, October 3, 2026

Linux aarch64 smoke runs used ReleaseFast and default synchronous LMDB commits,
with the same 16-conversation, 256-byte-message graph. The starting source was
the core of October 3, 2026. The changed source introduced exclusive
loading/resident cache states, checked resident envelopes and changed-page-only
directory staging. These are contract and footprint checks, not a throughput
comparison.

| Check | Before | After |
| --- | ---: | ---: |
| Ordinary cold retained Zig heap | 66,248 bytes | 65,992 bytes |
| Proposals for an insertion into an existing directory leaf | 4 | 1 |
| Allocations for that directory edit | Not separately measured | 2 |

The changed cache slot occupies 160 bytes, including its checked envelope.
The fixed 16-slot inventory does not grow. Hot calls still use zero backend
reads and writes, and eight calls make 16 allocations. The smoke run also
passes cold reads, managed calls, retained facets, worker admission and
collection checks. These short runs support no speedup claim.

The directory test fails on the starting implementation with four proposals
and passes with one proposal and two allocations. The resident-view test
rejects corrupted input before admission, repeatedly borrows the same payload
with allocation disabled, and bounds slot metadata. Historical-lease,
commit-adoption, cancellation, recovery and collector tests remain the authority
for their contracts.

## Recorded workload, September 15, 2026

The initial run used Linux aarch64, ReleaseFast, and synchronous LMDB
commits. The baseline used the core of September 15, 2026, with this workload before its
reload budget was added. Repeating the same graph and calls with commit-aware
residency produced these backend read counts for 4,096-byte messages:

| Conversation endpoints | 128 unrelated-edit rounds, before / after | Collection reads, 64-step batches, before / after | Collection reads, 256-step batches, before / after |
| ---: | ---: | ---: | ---: |
| 64 | 896 / 0 | 22 / 2 | 6 / 2 |
| 512 | 896 / 0 | 169 / 5 | 43 / 2 |
| 2,048 | 896 / 0 | 673 / 17 | 169 / 5 |

Each edit round commits one durable write. Remaining collection reads follow
batches that delete records. Regression tests and the smoke workload hold the
unchanged-record and historical-lease contracts. These counts say nothing about
comparative database performance.

The largest final population held 10,240 records and 2,048 callable endpoints.
Its tracked cold Zig heap was 1,308,432 bytes for either message size, with no
resident record buffers. Encoded records occupied 3,717,729 bytes with 256-byte
messages or 35,183,201 bytes with 4,096-byte messages. The corresponding LMDB
record trees occupied 4,853,760 and 68,620,288 bytes before collection.
The latter is nearly twice the encoded size: page geometry is a separate cost,
even when actor state can sleep. These figures exclude LMDB/OS residency.

For the 2,048-endpoint population with 4,096-byte messages, collection took 673
batches at 64 steps or 169 batches at 256 steps. The largest observed foreground
service times were about 8.0 ms and 11.6 ms respectively. Total collection time
was about 2.64 s and 0.96 s. Batch sizing trades aggregate durable-write cost
against the delay of a queued call. The concurrent scenario below measures
foreground scheduling. These single-run times are observations, not performance
limits.
