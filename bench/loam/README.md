# Native Loam workload

Run `zig build bench-loam -Doptimize=ReleaseFast` to measure the shipped Host/Vat,
record-backed actors, and LMDB backend together. Output names the optimization
mode, architecture, cache limits, and durability profile. The full run writes
`zig-out/bench-reports/loam.txt`. `-- --smoke` runs a small version under `check`.

Each population contains 64, 512, or 2,048 conversation headers, with four
message records per conversation. Headers are rooted actors holding strong
references to their latest messages. Each message has a strong previous-message
reference and a weak conversation reference. Messages contain 256 or 4,096 bytes.
They have no actor endpoints and remain outside the record cache during calls.
An edit increments a header version without changing its message chain.

This is a workload shaped like Rooms, not the Rooms application. It does not
exercise grants, subscriptions, search, Rust, the C ABI, or network sessions.

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
- **Wakeup bursts:** sixteen bursts of up to 64 calls, either to one cold
  header or to distinct cold headers. Latencies cover entire bursts, including
  admission and settlement. Read counts expose activation coalescing.
- **Collection:** unreachable pairs of draft records form cycles. Each batch
  admits a foreground read while the collection fence is held, verifies that
  it waits, commits, then settles that read. Reports include collected objects,
  batches, backend reloads, maximum fence and foreground service times, and
  extra Zig bytes observed immediately after collection preparation.
- **Physical storage:** native map size, allocated page high water, current
  record-tree pages, and entry counts before and after collection. High water
  is also sampled after each collection batch, outside its foreground latency
  sample. It includes reusable free pages and is not RSS or disk write volume.

LMDB uses its default synchronous commits. The harness executes backend work
synchronously at the executor boundary, outside actor turns. It measures local
service times, not worker scheduling, parallelism, sustained arrival rates, or
network latency. No artificial disk delay is inserted. Collection samples use
64 and 256 record/phase steps per batch; root seeding is additional work.

## Reading the evidence

Read and allocation counts are structural evidence. Wall-clock results depend
on the machine, filesystem, and competing work. Repeat runs on the same system
before drawing timing conclusions. Record the revision and command with each
saved report. All paths validate replies, collection totals, and complete Zig
allocation release. Hot reads and unrelated edits must cause no reloads;
same-target cold bursts must coalesce to one load. The smoke run holds these
structural costs without imposing a machine-dependent timing ceiling. It does
not establish a throughput target or correctness of capability authority.

The next application checks belong to the
[Loam implementation sequence](../../docs/planning/loam/architecture.md#implementation-order-and-acceptance).
Whole-process memory, major faults, reader retention, headroom under sustained
pressure, compaction, and concurrent executor interference need their own evidence.
Keep those costs separate from the 500,000 live CapTP session target.

## Recorded workload, September 15, 2026

The initial native run used Linux aarch64, ReleaseFast, and synchronous LMDB
commits. The baseline used the core at `9aa93cce8` with this workload before its
reload budget was added. Repeating the same graph and calls with commit-aware
residency produced these backend read counts for 4,096-byte messages:

| Conversation endpoints | 128 unrelated-edit rounds, before / after | Collection reads, 64-step batches, before / after | Collection reads, 256-step batches, before / after |
| ---: | ---: | ---: | ---: |
| 64 | 896 / 0 | 22 / 2 | 6 / 2 |
| 512 | 896 / 0 | 169 / 5 | 43 / 2 |
| 2,048 | 896 / 0 | 673 / 17 | 169 / 5 |

Each edit round still commits one durable write. Remaining collection reads
follow batches that delete records. Regression tests and the smoke workload
hold the unchanged-record and historical-lease contracts; these counts do not
establish comparative database performance.

The largest final population held 10,240 records and 2,048 callable endpoints.
Its tracked cold Zig heap was 1,308,432 bytes for either message size, with no
resident record buffers. Encoded records occupied 3,717,729 bytes with 256-byte
messages or 35,183,201 bytes with 4,096-byte messages. The corresponding native
record trees occupied 4,853,760 and 68,620,288 bytes before collection.
The latter is nearly twice the encoded size: page geometry is a separate cost,
even when actor state can sleep. These figures exclude LMDB/OS residency.

For the 2,048-endpoint population with 4,096-byte messages, collection took
673 batches at 64 steps or 169 batches at 256 steps. The largest observed
foreground service times were about 8.0 ms and 11.6 ms respectively. Total
collection time was about 2.64 s and 0.96 s. Batch sizing trades aggregate
durable-write cost against the delay of a queued call; scheduling policy still
needs concurrent-executor evidence. These single-run times are observations,
not performance limits.
