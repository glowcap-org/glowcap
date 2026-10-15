# Loam managed access results

These reports record measured managed access workloads at their stated
revisions. [The workload guide](README.md) owns the runnable profiles and
measurement boundaries, and [the other Loam results](results.md) cover
ordinary actors, collection, and residency.

These entries state the OS, architecture and software configuration, but
omit the hardware model, storage device and CPU placement. Use their timings
within each stated study, without assuming they describe another host.

## Recorded managed workload, October 1, 2026

The initial managed workload ran over core revision
`1f3560d12c121ccd7415ee9f04fd17761257f854` on Linux aarch64, using
`.agents/skills/work/bin/glowcap-dev zig build bench-loam -Doptimize=ReleaseFast`
and synchronous LMDB commits. The workload additions are the source beside
this report. The production core was unchanged. All six managed populations
passed reply, revocation, commit, reload and final allocation-release checks.

| Resources | Held use/control endpoints | Cold Zig heap bytes, either ancestry | Backend reads per cold call, shallow / four added ancestors |
| ---: | ---: | ---: | ---: |
| 64 | 128 | 111,104 | 16 / 24 |
| 512 | 1,024 | 655,768 | 16 / 24 |
| 2,048 | 4,096 | 2,457,464 | 16 / 24 |

The cold heap includes retained endpoints, reserved attachment tables, Host/Vat,
the Zig-level source-use binding and workload arrays. It excludes LMDB/OS residency.
Cache buffers were fully evicted for those measurements. Hot calls and the
three sibling reads following each content edit required no backend reads at
any population. Each edit or revoke group committed once, including its event
for revocation. Resident record buffers stayed within 4 MiB throughout.

These structural results do not imply constant call latency as the retained
endpoint population grows. The generated report records latency distributions
and local service throughput separately from the read budgets.

## Recorded executor and process memory, October 1, 2026

The executor additions ran over core revision `c4d3e0597f14aecd577fd8705bfc552c447685de`
on Linux aarch64 with Zig `0.17.0-dev.2127+e90365cd5`, ReleaseFast and default
synchronous LMDB commits. The command was
`.agents/skills/work/bin/glowcap-dev zig build bench-loam -Doptimize=ReleaseFast`.
The production core was unchanged.

Every sustained phase used four workers and eight admitted calls. Read and mixed
phases completed 1,024 calls each. Mixed phases committed 128 edits. Observed
pending bytes peaked at 32,768, below the 262,144-byte attachment limit.
Smoke separately verified executor refusal, attachment overload and progress
while a Zig-level collection commit was held. Tracked workload allocations returned
to zero after each population.

| Conversations | Mixed calls/s | Mixed p99 ms | Mixed RSS bytes | Mixed tracked Zig heap bytes |
| ---: | ---: | ---: | ---: | ---: |
| 64 | 2,828 | 9.91 | 12,853,248 | 227,184 |
| 512 | 3,027 | 8.80 | 28,397,568 | 485,662 |
| 2,048 | 3,050 | 8.41 | 82,026,496 | 1,447,198 |

At 2,048 conversations, 64-step collection used 673 batches. Transient
foreground p99 was 0.053 ms and fenced durable-read p99 was 7.20 ms.
256-step collection used 169 batches, with corresponding p99 values of
0.058 ms and 11.51 ms. Both preserved the 10,240 records reachable from rooted headers after
reclaiming each population's garbage. This is one closed-loop run, not a
throughput ceiling or a latency guarantee.

Cold managed RSS was 7,540,736 / 7,528,448 bytes at 64 resources,
10,207,232 / 10,174,464 at 512, and 17,195,008 / 16,449,536 at 2,048
for shallow / four-added-ancestor graphs. Their fully evicted record cache
and population-dependent retained Zig state remain reported separately.
These process snapshots include previous phases' allocator retention. They
cannot attribute all growth to Loam or isolate a fresh-process population.

## Recorded managed lifecycle, October 2, 2026

The complete workload passed at `743df69dd0779524c1cf7a355cc9b886af3c4ab6` on Linux aarch64
with Zig `0.17.0-dev.2127+e90365cd5`, ReleaseFast and synchronous LMDB commits:

```sh
.agents/skills/work/bin/glowcap-dev zig build bench-loam -Doptimize=ReleaseFast --summary failures
```

All six managed populations passed commit, reply, revocation, read-budget and
allocation-release checks. Each used 64 cache slots, 4 MiB of resident record
buffers, 32 model records per operation, eight admitted calls and 32 KiB of
pending calls. Scalar receipt-backed edits retained the 4 KiB call arena.
The conversation and sustained executor populations also passed.

| Resources | Cold Zig heap bytes, either ancestry | Reads for 128 move pairs, shallow / four added ancestors | Admitted children | Child-query reads, shallow / four added ancestors |
| ---: | ---: | ---: | ---: | ---: |
| 64 | 112,128 | 3,840 / 4,864 | 65 | 84 / 92 |
| 512 | 663,960 | 3,968 / 4,992 | 513 | 537 / 545 |
| 2,048 | 2,490,232 | 3,968 / 4,992 | 2,049 | 2,091 / 2,099 |

The child query includes the extra move container. Each move pair commits twice.
It needs 30–31 reads in the shallow graph and 38–39 with four added ancestors.
The query visits each admitted child with bounded model residency.

Cold control chains persist 32 descriptors in 32 commits at every population.
They use 784 reads and 944 allocations in shallow graphs, or 912 reads and
1,072 allocations with four added ancestors. Revoking the final control leaves
its held resource use active. Every population releases all tracked allocations.

At 2,048 resources, the run recorded these Zig-level phase timings:

| Phase and ancestry | Links or pairs per second | p50 ms | p99 ms |
| --- | ---: | ---: | ---: |
| Control link, 0 added ancestors | 350 | 2.894 | 4.352 |
| Control link, 4 added ancestors | 313 | 2.958 | 7.958 |
| Move pair, 0 added ancestors | 127 | 7.603 | 11.699 |
| Move pair, 4 added ancestors | 115 | 8.381 | 12.804 |

These timings are one run, with no timing acceptance threshold. Cold heap
includes workload arrays and endpoint custody. It excludes LMDB and OS memory.
The generated report keeps RSS, encoded data and physical pages separate.
Observation, terminal reclamation and long-lived retention were not measured
at this revision.

### Preparation and custody correction

The same full command passed at `743df69dd` on Linux aarch64 with the toolchain,
ReleaseFast mode and synchronous durability above. All six managed populations
and the ordinary conversation and sustained executor phases passed. Every
population released its tracked allocations. Cold retained heap, move read
counts and child-query read counts matched the preceding report.

Independent control changes stage the owner's control revision with the
descriptor. For 32 attenuation links, shallow graphs used 784 reads, 32 commits
and 1,008 allocations. Four added ancestors used 912 reads, 32 commits and 1,136
allocations. The extra 64 allocations encode and copy the 32 owner-header
updates into staging. Dependency admission refreshes its own descriptor using
fixed scratch after establishing current owner state.

At 2,048 resources, shallow / four-added-ancestor attenuation p99 was
4.747 / 3.916 ms and move-pair p99 was 11.195 / 13.688 ms. These are single-run
observations, with no timing acceptance threshold. The read, working set,
reply and release budgets stay enforced.

### Bounded change retention

The full workload passed at `743df69dd0779524c1cf7a355cc9b886af3c4ab6` on Linux
aarch64 with Zig `0.17.0-dev.2127+e90365cd5`, ReleaseFast and synchronous LMDB
commits, using the same full command above. All six managed populations,
ordinary conversations and sustained executor phases passed. Every population
released its tracked allocations. Managed record buffers stayed within 4 MiB.

Each owner retained exactly 32 batch edges after creation and sharing. Every
batch allows at most 16 effects and each affected path at most 65 identities.
Ordinary access still loads no history: cold calls used 16 / 24 reads for
shallow / four-added-ancestor graphs at every population. Hot reads and warmed
sibling reads after edits required zero backend reads. Only the first content
edit loaded the history root, once across all 128 edit groups. Subsequent edits
needed no backend read.

| Resources | Cold Zig heap bytes, either ancestry | Reads for 128 move pairs, shallow / four added ancestors | Child-query reads, shallow / four added ancestors |
| ---: | ---: | ---: | ---: |
| 64 | 112,128 | 4,096 / 5,632 | 84 / 92 |
| 512 | 663,960 | 4,224 / 5,760 | 537 / 545 |
| 2,048 | 2,490,232 | 4,224 / 5,760 | 2,091 / 2,099 |

Cold heap and child-query reads match the preceding correction. Moves load
retained history and the complete affected ancestry for scoped subtree stamps.
Each pair commits twice and requires 32–33 reads in shallow graphs or 44–45 with
four added ancestors. This is independent of population apart from the
sparse-directory page difference.

For 32 cold attenuation links, every population used 816 reads, 32 commits and
1,168 allocations in shallow graphs, or 944 reads and 1,296 allocations with
four added ancestors. Each link creates one control descriptor and one batch.
The history root is updated in that same transaction. Its final revocation
leaves use authority active. At 2,048 resources, shallow / deeper control
p99 was 4.293 / 3.601 ms, and move-pair p99 was 11.308 / 13.818 ms. These are
single-run measurements without timing thresholds.

Stored footprints include expired batch records until tracing collects them.
This workload does not run managed reclamation. Retained batch edges are bounded,
while collection of expired history is proved by the volatile and LMDB tests.
Observer contexts, replay fanout, terminal reclamation and long-lived
retention were not measured at this revision.

The Zig-level observation phases
measure registration, cold unchanged polls, 32-context pause/resume fanout and
cancellation with quota reuse. Smoke tests bound reads, commits, retained
records and release of Zig-level operations. Later reports below cover hosted
parked-call memory, terminal reclamation and declared retention working sets.

### Scoped Zig-level observation

The full workload passed at `92633345dae8d917bc07cfb0d31505ea2f41ebfd` on
Linux aarch64 with Zig `0.17.0-dev.2127+e90365cd5`, ReleaseFast and synchronous
LMDB commits, using the full command above. All six managed populations,
ordinary conversations and sustained executor phases passed. Tracked allocations
were released completely, and managed record buffers stayed within 4 MiB.
Cold managed access still used 16 / 24 reads for shallow / four-added-ancestor
graphs, independent of population. Observation does not add history reads to
ordinary access.

Each population registered 32 Zig-level contexts, polled them cold without changes,
then delivered 16 alternating pause/resume commits to all 32 contexts. These
512 polls measure bounded replay fanout. The contexts retain the parent's exact
use descriptor and target. They add 33 records including the owner index.
A 33rd registration refused without committing. Cancellation closed all contexts,
then registration and cancellation of one replacement proved quota reuse.

| Phase | Operations | Reads, shallow / four added ancestors | Commits | Allocations, shallow / four added ancestors |
| --- | ---: | ---: | ---: | ---: |
| Registration and initial poll | 32 | 103 / 107 | 32 | 588 / 856 |
| Cold unchanged poll | 32 | 44 / 52 | 0 | 172 / 180 |
| Pause/resume fanout | 512 | 697 / 793 | 16 | 3,913 / 4,137 |
| Cancellation and quota reuse | 32 cancellations plus two quota-check operations | 61 / 77 | 34 | 270 / 294 |

These counts were identical at 64, 512 and 2,048 resources. Fanout does not scan
unrelated grants or resources. Each phase ended with zero live Zig-level source
or observation operations. The cancellation latency samples cover the initial
32 cancellations. Its aggregate costs also include the replacement's two commits.

| Resources | Unchanged poll p99, shallow / four added ancestors | Fanout poll p99, shallow / four added ancestors | Zig heap after registration, either ancestry | Logical record bytes after registration, shallow / four added ancestors |
| ---: | ---: | ---: | ---: | ---: |
| 64 | 76 / 370 µs | 86 / 384 µs | 4,311,638 | 391,409 / 413,150 |
| 512 | 135 / 545 µs | 169 / 550 µs | 4,861,358 | 1,405,281 / 1,442,875 |
| 2,048 | 144 / 550 µs | 180 / 589 µs | 6,687,054 | 4,860,677 / 4,947,984 |

Registration p99 ranged from 3.8 to 13.4 ms, and cancellation p99 from 3.1 to
3.9 ms. These are single-run observations without timing thresholds. After registration,
4,194,304 heap bytes belonged to resident record buffers at every population.

At 2,048 resources, process RSS across observation phases was 20,635,648 /
21,450,752 bytes for shallow / deeper ancestry. Process memory includes previous
phases and allocator retention. It cannot isolate the cost of a fresh observer.
Logical record bytes likewise include earlier lifecycle work and expired history.

The [CapTP stress proof](../../test/loam/access/observation_hosted_test.zig)
separately wakes and cancels 32 parked receivers under declared storage, ingress,
retention and transport budgets. This Zig-level report does not measure those
parked call arenas or network delivery latency. Terminal reclamation is measured
below, and later reference and retention reports cover hosted parked-call
memory and returned facets under their declared working sets.

### Bounded managed retirement

The full workload passed at `92633345dae8d917bc07cfb0d31505ea2f41ebfd` on
Linux aarch64 with Zig `0.17.0-dev.2127+e90365cd5`, ReleaseFast and synchronous
LMDB commits, using the full command above. All ordinary, managed and sustained
executor phases passed. Teardown released every tracked allocation. Managed
record buffers remained within 4 MiB. Ordinary cold access still used 16 / 24
reads per call for shallow / four-added-ancestor graphs at every population.

The collector snapshot allows two held endpoints per resource plus
the Zig-level issuer and owner administrator. Every maintenance step starts cold.
Reads, commits and allocations below include the collection after each phase.
Maximum step reads and latency exclude collection.

Sweep work checks live
admission and prunes terminal indexes. Owner retirement closes admission, then
compacts the remaining indexed records and drops owner roots. Neither phase
scans unrelated owners.

| Resources | Added ancestry | Phase | Steps | Reads | Maximum step reads | Commits | Allocations |
| ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 64 | 0 | sweep | 425 | 3,470 | 11 | 453 | 10,541 |
| 64 | 0 | retire-owner | 73 | 414 | 6 | 85 | 1,677 |
| 64 | 4 | sweep | 433 | 3,788 | 15 | 462 | 11,435 |
| 64 | 4 | retire-owner | 81 | 462 | 6 | 94 | 1,869 |
| 512 | 0 | sweep | 3,113 | 34,068 | 19 | 3,331 | 66,150 |
| 512 | 0 | retire-owner | 2,441 | 14,622 | 6 | 2,572 | 57,726 |
| 512 | 4 | sweep | 3,121 | 42,342 | 23 | 3,341 | 75,530 |
| 512 | 4 | retire-owner | 2,449 | 14,670 | 6 | 2,581 | 57,923 |
| 2,048 | 0 | sweep | 12,329 | 146,196 | 19 | 13,222 | 254,244 |
| 2,048 | 0 | retire-owner | 11,657 | 69,918 | 6 | 12,221 | 276,943 |
| 2,048 | 4 | sweep | 12,337 | 185,190 | 23 | 13,231 | 294,334 |
| 2,048 | 4 | retire-owner | 11,665 | 69,966 | 6 | 12,230 | 277,143 |

| Resources | Added ancestry | Bytes after initial trace | Bytes after sweep | Bytes after owner retirement | Retained records after retirement | Zig heap after retirement |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 64 | 0 | 148,731 | 48,511 | 16,545 | 130 | 187,836 |
| 64 | 4 | 156,197 | 55,717 | 16,550 | 130 | 187,836 |
| 512 | 0 | 1,042,785 | 850,295 | 130,407 | 1,026 | 737,569 |
| 512 | 4 | 1,050,311 | 857,550 | 130,407 | 1,026 | 737,569 |
| 2,048 | 0 | 4,129,091 | 3,936,117 | 524,399 | 4,098 | 2,563,272 |
| 2,048 | 4 | 4,136,681 | 3,943,440 | 524,399 | 4,098 | 2,563,272 |

Those remaining records are the held resource endpoints, Zig-level issuer descriptor
and minimal owner header. They contain refusal metadata and no former
content, authority dependencies or receipt payloads. Release of their custody
permits shared tracing to reclaim them. The LMDB reopen proof separately reaches
one remaining owner header after all endpoints are released.

Every run preserved 32 immutable durable-name reservations: **1,856 logical
bytes**, or **58 bytes each**, before backend overhead. The final backend held
one metadata entry, those 32 reservations and exactly the reported retained
records. Logical record bytes above exclude name-index entries. Collection
makes pages reusable but does not shrink the LMDB file.

Minting also pays for atomic weak identity registration. Zig-level sharing prepares
at most four sparse index paths, while ordinary reads prepare none. Sharing cost
for the same full populations was:

| Resources | Sharing reads, shallow / deeper ancestry | Sharing allocations, shallow / deeper ancestry | Sharing commits |
| ---: | ---: | ---: | ---: |
| 64 | 902 / 1,162 | 5,603 / 6,375 | 64 |
| 512 | 7,174 / 9,226 | 44,598 / 50,746 | 512 |
| 2,048 | 28,678 / 36,874 | 178,242 / 202,822 | 2,048 |

Step latency samples every sixteenth operation. Across the six managed cases,
sampled p99 ranged from 2.80 to 4.92 ms. These are single-run observations
without timing thresholds.

At 2,048 resources, whole-process RSS after retirement
was 24,674,304 / 25,026,560 bytes for shallow / deeper ancestry.
RSS includes preceding phases, LMDB and allocator retention. It does not isolate
fresh cleanup cost. The churn tests separately bound records and bytes over
32 create/share/revoke/delete cycles while preserving delegation capacity and
identity floors.

This run did not measure hosted parked receivers, returned facets, larger
retention working sets or compaction costs. The two reports that follow cover
them. This run establishes Linux process and workload behavior, with no macOS
execution or hardware power-loss evidence.

## Recorded returned authority and parked calls, October 2, 2026

Implementation `272d70e7c400b795b4b0e8b1db3b9b4797a2927d` passed
`zig build bench-loam -Doptimize=ReleaseFast -- --references-only` through the
checkout's `glowcap-dev` front on Linux aarch64 with Zig
`0.17.0-dev.2127+e90365cd5` and default synchronous LMDB commits.
The complete report is regenerated at `zig-out/bench-reports/loam-references.txt`.
Record envelope 2 and metadata 3 apply to this population.

Each row measures 128 groups that return a capability and call it, plus one
final local call that retires released actor boxes. Throughput includes all
257 calls. Latency describes a two-call group. Each row writes no records.
The self-reference stays inside the resource's object-scoped grant. These
local calls use a byte-fed witness session without sockets.

| Resources | Extra ancestry | Return | Reads | Allocations | Calls/s | Group p50 µs | Group p99 µs |
| ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 64 | 0 | exact | 16 | 2,592 | 12,127 | 163.3 | 173.5 |
| 64 | 0 | dependent | 0 | 3,205 | 6,758 | 295.6 | 302.7 |
| 64 | 4 | exact | 24 | 2,600 | 2,985 | 669.2 | 678.6 |
| 64 | 4 | dependent | 0 | 3,205 | 1,095 | 1829.2 | 1838.6 |
| 512 | 0 | exact | 16 | 2,593 | 5,114 | 439.2 | 531.4 |
| 512 | 0 | dependent | 0 | 3,589 | 4,087 | 489.2 | 498.5 |
| 512 | 4 | exact | 24 | 2,601 | 1,909 | 1046.0 | 1078.2 |
| 512 | 4 | dependent | 0 | 3,589 | 832 | 2406.5 | 2422.5 |
| 2,048 | 0 | exact | 16 | 2,593 | 5,231 | 452.5 | 543.2 |
| 2,048 | 0 | dependent | 0 | 3,589 | 3,992 | 501.2 | 505.9 |
| 2,048 | 4 | exact | 24 | 2,601 | 1,750 | 1065.4 | 1643.0 |
| 2,048 | 4 | dependent | 0 | 3,589 | 820 | 2442.9 | 2459.9 |

Eight separately retained facets survived 32 complete collection rounds and
remained callable. With zero resident record bytes, their net retained heap
increase was 704 bytes at 64 resources and 768 bytes at 512 and 2,048 resources,
for both ancestry depths. The measured heap after collection includes all
population metadata and Host custody. This delta measures the declared eight facets only.

Eight cold calls added 110,072 retained Zig bytes at every population and depth.
That includes 32,768 admitted attachment bytes, eight 512-byte owned reply
buffers, operation objects, preparation state and the coalesced read buffer.
They shared one backend read, refused a ninth call, and all completed. Every
population then released all counted Zig allocations. Process snapshots record
whole-process memory separately in the regenerated report.

The ownership regressions detect aggregate destruction through freed session
indexes, temporary local reply export roots and nested wire staging in a local
listener. The restored implementations pass. The wire-forwarding scenario also
returns every peer-held occurrence to its session baseline. These measurements
cover eight held facets and an eight-call window. The managed execution report
extends to foreign restoration, pool workers, larger retention working sets
and offline compaction. Timings describe this run and set no throughput target.

## Recorded managed execution and restoration, October 2, 2026

Measured source: `272d70e7c400b795b4b0e8b1db3b9b4797a2927d`, including the
actor retirement correction. Linux aarch64, Zig
`0.17.0-dev.2127+e90365cd5`, ReleaseFast, LMDB default synchronous durability,
record envelope 2 and metadata 3. The checkout's `glowcap-dev` front ran:

```sh
zig build bench-loam -Doptimize=ReleaseFast -- --managed-only
```

The command exited successfully and writes the complete report to
`zig-out/bench-reports/loam-managed.txt`. It includes the existing managed
lifecycle, observation, receipts, retirement and permanent name-reservation
measurements, plus the profiles below. Every population released all counted
Zig allocations on teardown. Worker/control allocations and LMDB memory
remain outside that counter. Process snapshots include their resident cost.

Each worker row admits 1,024 calls through four persistent workers and an
eight-call window. Mixed rows edit every eighth admission and must commit
exactly 128 writes. Read rows commit none.

The managed profile uses 64 cache
slots, 4 MiB residency, 258 leases, 4 KiB per call, 32 KiB pending calls and
512-byte forwarded replies. Calibration holds a Zig-level collection commit,
refuses the ninth managed call, and requires unrelated actor progress.
Latency is per call. Elapsed time also includes completion installation.

Each foreign row runs 128 two-call groups against 32 rooted target publications,
plus one cleanup call included in throughput. Both Zig-level caches are evicted
before every group. Exact and dependent returns must call zero-valued target
content. Dependent calls also evaluate the current source grant.

Established rows perform no name lookup. Fresh rows perform exactly 128. Group latency
excludes cleanup. Fresh rows include session retirement and a new byte-fed
handshake, with no socket or transport authentication latency. Writes remain
zero.

The report separates cleanup reads and counts actual protocol frames
and bytes. Per-group source reads stay within 17 plus two per added ancestor.
Targets read at most one content and one publication record.

Retention rows hold 8, 32 or 128 facets through 32 complete collection-and-call
rounds. The 128-holder window has 64 distinct targets at 64 resources, and
128 at larger populations. Every facet stays callable with zero resident
record bytes. Whole retained heap remains exactly unchanged after the first
round.

The table separates capability slot-array capacity growth from total
heap delta. The remaining facet cost stays below 1 KiB per holder. Setup is
included in aggregate counters and throughput. Latency is one complete round.

A reduced-round reproduction calibrated this attribution: 128 holders at
2,048 resources expand capability slots from 4,159 to 6,241. The actual slot
type contributes 166,560 bytes, leaving 12,288 bytes of facet state and other
index cost. Attributing the whole 178,848-byte increase to facets failed the facet
budget, so slot-array capacity is accounted separately. The complete heap,
residency and repeated-round checks are unchanged.

Compaction begins after worker shutdown and Store destruction. It compares all
stored keys/values before replacement. A fresh normal opening verifies exact
metadata with its expected new incarnation and the same entry count. Physical
high water includes engine page history. Tree bytes describe the live tree.
Elapsed time covers the offline operation, separately from reopening.

### Sustained workers

| Resources | Ancestry | Phase | Reads | Writes | Allocations | Calls/s | Call p50 µs | Call p99 µs | Peak pending B |
| ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 64 | 0 | read | 5075 | 0 | 10195 | 8641 | 598.9 | 7060.9 | 32768 |
| 64 | 0 | mixed | 5317 | 128 | 13074 | 2158 | 3351.9 | 16595.8 | 32768 |
| 64 | 4 | read | 5105 | 0 | 10227 | 2648 | 2003.0 | 24579.4 | 32768 |
| 64 | 4 | mixed | 5395 | 128 | 14110 | 1347 | 5144.5 | 21833.6 | 32768 |
| 512 | 0 | read | 5164 | 0 | 10285 | 5484 | 961.5 | 7502.7 | 32768 |
| 512 | 0 | mixed | 5371 | 128 | 13119 | 1970 | 3537.8 | 18624.7 | 32768 |
| 512 | 4 | read | 5203 | 0 | 10326 | 1737 | 3280.0 | 37864.1 | 32768 |
| 512 | 4 | mixed | 5413 | 128 | 14157 | 992 | 6881.1 | 32214.9 | 32768 |
| 2048 | 0 | read | 5192 | 0 | 10313 | 6118 | 842.2 | 7748.9 | 32768 |
| 2048 | 0 | mixed | 5320 | 128 | 13076 | 1948 | 3675.6 | 17364.9 | 32768 |
| 2048 | 4 | read | 5202 | 0 | 10325 | 1793 | 3170.3 | 25348.9 | 32768 |
| 2048 | 4 | mixed | 5434 | 128 | 14190 | 1056 | 6425.5 | 28932.5 | 32768 |

### Foreign fields

| Resources | Ancestry | Return | Session | Source reads | Target reads | Lookups | Allocations | Calls/s | Group p50 µs | Group p99 µs |
| ---: | ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 64 | 0 | exact | established | 2181 | 128 | 0 | 9502 | 11537 | 171.0 | 177.9 |
| 64 | 0 | dependent | established | 2181 | 128 | 0 | 10764 | 7861 | 253.7 | 258.3 |
| 64 | 0 | exact | fresh | 2181 | 256 | 128 | 19979 | 4264 | 468.7 | 475.6 |
| 64 | 0 | dependent | fresh | 2181 | 256 | 128 | 21007 | 3632 | 551.3 | 556.1 |
| 64 | 4 | exact | established | 3205 | 128 | 0 | 10526 | 2797 | 564.6 | 937.0 |
| 64 | 4 | dependent | established | 3205 | 128 | 0 | 11788 | 2240 | 893.0 | 897.5 |
| 64 | 4 | exact | fresh | 3205 | 256 | 128 | 21003 | 1946 | 1027.0 | 1060.9 |
| 64 | 4 | dependent | fresh | 3205 | 256 | 128 | 22031 | 1468 | 1364.1 | 1375.9 |
| 512 | 0 | exact | established | 2181 | 128 | 0 | 9503 | 7436 | 266.3 | 277.6 |
| 512 | 0 | dependent | established | 2181 | 128 | 0 | 11148 | 4833 | 413.1 | 418.8 |
| 512 | 0 | exact | fresh | 2181 | 256 | 128 | 19979 | 3535 | 565.0 | 602.1 |
| 512 | 0 | dependent | fresh | 2181 | 256 | 128 | 21391 | 2815 | 711.4 | 718.5 |
| 512 | 4 | exact | established | 3205 | 128 | 0 | 10527 | 2146 | 778.7 | 1223.6 |
| 512 | 4 | dependent | established | 3205 | 128 | 0 | 12172 | 1536 | 1300.9 | 1309.2 |
| 512 | 4 | exact | fresh | 3205 | 256 | 128 | 21003 | 1598 | 1250.4 | 1262.5 |
| 512 | 4 | dependent | fresh | 3205 | 256 | 128 | 22415 | 1129 | 1773.4 | 1780.0 |
| 2048 | 0 | exact | established | 2181 | 128 | 0 | 9503 | 4550 | 443.8 | 538.0 |
| 2048 | 0 | dependent | established | 2181 | 128 | 0 | 11148 | 4703 | 424.7 | 436.5 |
| 2048 | 0 | exact | fresh | 2181 | 256 | 128 | 19979 | 3488 | 573.0 | 578.6 |
| 2048 | 0 | dependent | fresh | 2181 | 256 | 128 | 21391 | 2770 | 722.9 | 728.7 |
| 2048 | 4 | exact | established | 3205 | 128 | 0 | 10527 | 2510 | 793.2 | 809.5 |
| 2048 | 4 | dependent | established | 3205 | 128 | 0 | 12172 | 1506 | 1327.3 | 1343.3 |
| 2048 | 4 | exact | fresh | 3205 | 256 | 128 | 21003 | 1574 | 1269.2 | 1289.3 |
| 2048 | 4 | dependent | fresh | 3205 | 256 | 128 | 22415 | 1110 | 1803.8 | 1821.1 |

### Retained facets

| Resources | Ancestry | Holders | Reads | Writes | Allocations | Calls/s | Round p50 ms | Round p99 ms | Retained delta B | Slot growth B | Facet delta B |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 64 | 0 | 8 | 1632 | 1024 | 13250 | 91 | 90.5 | 105.1 | 320 | 0 | 320 |
| 64 | 0 | 32 | 5632 | 1024 | 27522 | 354 | 93.3 | 104.9 | 9992 | 6480 | 3512 |
| 64 | 0 | 128 | 21472 | 1024 | 84453 | 971 | 139.3 | 160.5 | 48440 | 9760 | 38680 |
| 64 | 4 | 8 | 1888 | 1088 | 14018 | 75 | 108.2 | 128.5 | 320 | 0 | 320 |
| 64 | 4 | 32 | 5888 | 1088 | 28290 | 234 | 139.5 | 162.9 | 9992 | 6480 | 3512 |
| 64 | 4 | 128 | 21728 | 1088 | 85221 | 446 | 293.9 | 311.2 | 48440 | 9760 | 38680 |
| 512 | 0 | 8 | 1632 | 7328 | 100339 | 11 | 713.3 | 818.9 | 320 | 0 | 320 |
| 512 | 0 | 32 | 5632 | 7328 | 114656 | 46 | 714.3 | 823.5 | 3072 | 0 | 3072 |
| 512 | 0 | 128 | 21472 | 7328 | 171776 | 183 | 725.2 | 814.8 | 12288 | 0 | 12288 |
| 512 | 4 | 8 | 1888 | 7392 | 101427 | 10 | 766.8 | 946.8 | 320 | 0 | 320 |
| 512 | 4 | 32 | 5888 | 7392 | 115744 | 44 | 747.8 | 791.5 | 3072 | 0 | 3072 |
| 512 | 4 | 128 | 21728 | 7392 | 172864 | 140 | 921.6 | 1101.7 | 12288 | 0 | 12288 |
| 2048 | 0 | 8 | 1632 | 28928 | 467923 | 2 | 4037.4 | 4433.2 | 320 | 0 | 320 |
| 2048 | 0 | 32 | 5632 | 28928 | 482240 | 8 | 3797.0 | 4343.1 | 3072 | 0 | 3072 |
| 2048 | 0 | 128 | 21472 | 28928 | 539361 | 36 | 3545.9 | 4355.2 | 178848 | 166560 | 12288 |
| 2048 | 4 | 8 | 1888 | 28960 | 468691 | 2 | 3841.0 | 4382.0 | 320 | 0 | 320 |
| 2048 | 4 | 32 | 5888 | 28960 | 483008 | 9 | 3536.1 | 4311.7 | 3072 | 0 | 3072 |
| 2048 | 4 | 128 | 21728 | 28960 | 540129 | 34 | 3768.2 | 4528.1 | 178848 | 166560 | 12288 |

### Compaction

| Resources | Ancestry | Entries | High water before B | High water after B | Tree before B | Tree after B | Elapsed ms |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 64 | 0 | 763 | 376832 | 311296 | 290816 | 290816 | 11.1 |
| 64 | 4 | 787 | 417792 | 335872 | 315392 | 315392 | 10.4 |
| 512 | 0 | 3912 | 2256896 | 1765376 | 1740800 | 1740800 | 12.0 |
| 512 | 4 | 3936 | 2342912 | 1859584 | 1835008 | 1835008 | 13.5 |
| 2048 | 0 | 14706 | 9015296 | 6918144 | 6893568 | 6893568 | 15.0 |
| 2048 | 4 | 14730 | 9244672 | 7139328 | 7114752 | 7114752 | 18.6 |

### Foreign startup

| Resources | Ancestry | Counted startup B | Source records B | Target records B |
| ---: | ---: | ---: | ---: | ---: |
| 64 | 0 | 226488 | 164725 | 62643 |
| 64 | 4 | 226488 | 175223 | 62643 |
| 512 | 0 | 778320 | 1234815 | 62643 |
| 512 | 4 | 778320 | 1260301 | 62643 |
| 2048 | 0 | 2604592 | 4948000 | 62643 |
| 2048 | 4 | 2604592 | 5023221 | 62643 |

### Process memory snapshots

| Resources | Ancestry | Worker startup Zig B | Largest worker RSS snapshot B | Foreign startup RSS B | Foreign virtual B |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 64 | 0 | 117872 | 18862080 | 20529152 | 825843712 |
| 64 | 4 | 117872 | 19320832 | 17833984 | 824913920 |
| 512 | 0 | 669704 | 21397504 | 21745664 | 825393152 |
| 512 | 4 | 669704 | 21712896 | 21856256 | 825393152 |
| 2048 | 0 | 2495976 | 29339648 | 28975104 | 827432960 |
| 2048 | 4 | 2495976 | 29573120 | 29261824 | 827432960 |

RSS and address space belong to the entire process, including allocator
high water, thread stacks, LMDB storage and earlier phases. The largest
worker snapshot is a sampled value, not a transient phase peak. Lifetime peak
RSS and faults remain separate fields in the complete report. These fed-byte
profiles establish no live transport latency, open-loop arrival-rate ceiling,
maximum throughput, macOS execution or hardware power-loss claim.
