---
type: living
description: What the benchmarks measure and the runs recorded so far.
sources:
  - resource: /bench/
---

# Benchmarks

The benchmarks measure what glowcap costs. They never decide behavior, which
is the tests' job. [Build steps](../docs/build-steps.md) lists every `bench-*`
step. Absolute figures come from `-Doptimize=ReleaseFast` runs, and a smoke
run only proves a bench still runs.

Record the date, source revision, hardware
model, CPU, RAM, kernel, filesystem and storage device with latency results.
Link to that environment when several studies share it. Measure
code that matches `dev`, on a host with nothing else running: another build on
the same cores moves every figure.

## Profiles

A `profile-<bench>` step runs the bench under callgrind and writes
`zig-out/bench-reports/<bench>-profile.md`: for each phase the bench marks,
the self cost per source file and per function, ranked, and the callers of the
leaf functions at the top. Read it this way:

- Instructions retired (Ir) is the unit. It does not move with load, clock,
  or cache state, so two runs of one build repeat it exactly and a before and
  after diff of Ir on the same phase is evidence on its own, with no quiet
  machine needed.
- Self cost is the ranking. The build is ReleaseFast, so inclusive cost and
  call trees follow inlining and mislead. A function high on the list is where
  the instructions execute, and the bench's own source says who asked.
- A leaf such as `memcpy` or a decoder runs for many callers, and its cost at
  each call site is exact. The callers table under it says whose copy or
  decode it was, with the calls and the instructions the leaf ran for each.
- Each marked phase is one part, collected on its own. Setup and teardown
  between phases run uninstrumented and count nothing.
- A profile ranks cost inside one run of the bench. The bench's ReleaseFast
  wall-clock figure is still the claim a change makes, so profile first, change
  the top of the list, then measure.

A bench marks a phase with `bench/support/profile.zig`: `begin()` before the
timed loop and `end("<phase>")` after it. The marks compile to nothing in the
ordinary bench build.

## Floors

`zig build bench-floors` times each primitive alone, with nothing of glowcap
around it. A product path is then judged against the floors it pays, and not
only against its own last run. A path whose work is the protocol itself has
no primitive floor and answers to the `perf-check` ceilings instead.

Measured 2026-10-13 on the machine the scale run below names. Each floor is a
mean over its iteration count: 2,000 for the crypto rows (sign, verify, and the
handshake), 200,000 for the record and copy rows, and 20,000 for the thread
wake and the loopback rows. The product rows are p50 over 3,000 calls, so the
ratio column compares a mean floor with a median path. The round-trip rows are
measured with both threads pinned to one CPU (`--pin=6,6` or `taskset -c <cpu>`),
because unpinned runs on this machine spread from 28 µs to 45 µs with its
cross-core wake latency. The busy-poll rows run with each runtime on its own
core (`--pin=6,7`), since a spinning runtime that shares a core with its
partner waits out its whole window on every call.

| Floor | Pinning | Cost |
| --- | --- | --- |
| Ed25519 sign, 64-byte payload | not pinned, one thread | 31.0 µs |
| Ed25519 verify | not pinned, one thread | 37.1 µs |
| Noise XK handshake, both roles in one process, fresh ephemerals | not pinned, one thread | 223.8 µs |
| Noise record seal or open, 1 KiB | not pinned, one thread | 1.1 µs each |
| frame copy, 1 KiB and 16 KiB | not pinned, one thread | 13 ns and 148 ns |
| thread wake round trip, one event each way | one core (`--pin=6,6`) | 1.2 µs |
| thread wake round trip, one event each way | one core each (`--pin=6,7`) | 4.5 µs |
| loopback TCP round trip, 64 bytes, blocking sockets | one core (`--pin=6,6`) | 4.0 µs |
| loopback TCP round trip, 64 bytes, blocking sockets | one core each (`--pin=6,7`) | 9.1 µs |
| loopback TCP round trip, 64 bytes, both sides spinning on nonblocking sockets | one core each (`--pin=6,7`) | 4.7 µs |

| Product path | Measured | Floors it pays | Ratio |
| --- | --- | --- | --- |
| warm inbound turn (`bench-dispatch-scaling`, one peer) | 284 ns | one 1 KiB frame copy, then the protocol | ceiling only |
| answered outbound send (`bench-outbound`) | 851 ns | one 1 KiB frame copy, then the protocol | ceiling only |
| one `tcp` call round trip through `driver.Session` (`bench-iroh --pin=6,6`, p50, two pinned runs of 2026-10-14 within 0.1 µs) | 8.9 µs | one pinned loopback round trip, two inbound turns, two sends: 6.3 µs | 1.4× |
| one `inproc` call round trip through `driver.Session` (`bench-iroh --transport=inproc`, p50, three pinned runs within 0.2 µs) | 8.5 µs | one pinned thread wake round trip, two inbound turns, two sends: 3.4 µs | 2.5× |
| one `tcp` call round trip with both runtimes spinning (`bench-iroh --busy-poll-us=50 --pin=6,7`, p50, three runs within 0.1 µs) | 10.8 µs | one spinning loopback round trip, two inbound turns, two sends: 7.0 µs | 1.5× |
| one `inproc` call round trip with both runtimes spinning (`bench-iroh --transport=inproc --busy-poll-us=50 --pin=6,7`, p50, three runs within 0.1 µs) | 4.3 µs | two inbound turns, two sends: 2.3 µs | 1.9× |
| one `noise-tcp` call round trip through `driver.Session` (`bench-iroh --transport=noise-tcp --pin=6,6`, p50, three pinned runs within 0.3 µs) | 13.4 µs | one pinned loopback round trip, four record seal-or-open operations (a seal and an open each way), two inbound turns, two sends: 10.7 µs | 1.3× |
| opening one `tcp` session: connect, one fetch, close (`bench-iroh --transport=tcp --pin=6,6`, p50, two pinned runs of 2026-10-14 within 0.6 µs) | 338 µs | two pinned loopback round trips for the handshake legs, two Ed25519 signs, two verifies: 144 µs, which leaves out the fetch round trip and the close | 2.3× |
| opening one `noise-tcp` session: connect, one fetch, close (`bench-iroh --transport=noise-tcp --pin=6,6`, p50, three pinned runs within 11 µs) | 769 µs | the `tcp` floors plus one Noise XK handshake: 368 µs, which leaves out the fetch round trip and the close | 2.1× |

A ratio above 2× is a gap, and the [roadmap](../docs/roadmap.md) tracks the
work on it. Both session-open rows are above it. Each sample spans the dial,
the handshake, the first fetch, and the teardown, and the floors leave out
the socket setup and the session's allocation.

The syscall profile behind the round-trip row is `strace -f -c`
on `glowcap-iroh-bench --transport=tcp --smoke` in the devcontainer, read as
calls per round trip: one `tcp` call enters the ring four times, one
submit and one park on each side. A park is a wait inside the ring, which
runs the receive work the kernel owes the thread before it checks the
queue, so a reply wakes the thread once. A re-armed receive rides the next
park's submit, so a call that only consumed its reply submits nothing as it
returns.

An `inproc` call moves its bytes through
memory and enters the kernel only to wake the other thread, which costs one
socket send, one park, one receive to drain, and one ring enter per
direction, so the row sits near the `tcp` one. With a busy-poll window
(`HostRuntime.Options.busy_poll_ns`) a runtime spins and reaps its residents
instead of parking, so the same `tcp` call parks zero times and still enters
the ring twice. An `inproc` writer nudges only a parked reader, so
the spinning `inproc` call makes no syscall at all and its 4.3 µs is the
round trip's userspace alone. On the same two cores the parked rows
measure 13.0 µs for `tcp` and 11.8 µs for `inproc`.

The parked `inproc` row stays above 2× of its floor. The transport is for
tests, where two hosts share one process, and its cost is the thread-wake
floor plus the re-arm of the ring receive on each nudge. Folding the nudge
into one ring operation would tie `inproc` to io_uring, and an application
that cares about the last microseconds in one process runs the busy-poll
row instead.

The instruction profile behind it is `callgrind` on the same binary built with `-Dcpu=baseline`, since valgrind's
JIT lacks an instruction the host-CPU build uses. Instructions per round trip
are the difference between the full run and the smoke run divided by the
calls between them, which leaves the handshake out, with `--row=greet` so
the session-open row stays out of both. The count has a floor: three runs of
one binary spread by about 70 instructions on the caller, from how often it
parks per call, and by under 5 on the server, so a change is read on the
server thread and a caller delta inside the spread is not a result. One
`tcp` round trip runs about 43,000 userspace instructions over both threads,
23,700 on the caller and 19,400 on the server, and no single function holds
more than about three percent of it. Grouped by what the code is doing,
summed over both threads and rounded to the hundred, from the 44,400 run
the grouping was taken at:

| Concern | Instructions | What it is |
| --- | --- | --- |
| session and engine | 9,400 | validating the message, the export and answer tables, the event, the outbound queue |
| host and runtime | 6,300 | the action pump, the session's feed and drain, the capability lift and lower |
| completion chain and ring | 6,100 | the resident, the adapters it wraps, the io_uring submit and reap |
| tables | 5,100 | the keyed and identity hashes left on the path and the handle tables |
| allocation | 4,300 | the owned frame per retained event, two outbound encodes, the vow value, one answer payload |
| Syrup decode | 4,400 | the digit scans, the label matches, and the structural walk |
| Syrup encode | 2,400 | the measure and fill passes of two records per side |
| Vat | 1,100 | admission, the turn, and the ingress queue |
| copies | 900 | a dozen short copies of fifteen to seventy instructions each, none of a frame |
| foundation | 700 | frames, the stream prefix, the sealed channel's bookkeeping |
| other | 5,600 | bodies callgrind attributes to no file, the c allocator's shims, one sort |

The rows sum past the total by about two thousand, because a function the
shorter run spent more on than the longer one counts for nothing here. Each
row names the mechanism that stays rather than a loop to tune: a further cut
is a seam, such as fewer tables on the path or fewer owned values per
message, and each of those is a design decision with an ADR.

## Against Cap'n Proto

`zig build bench-capnp` times two Cap'n Proto RPC calls in the C++ reference
library and in the `capnp-rpc` Rust crate, each as one process with a client
thread and a server thread over loopback TCP, parked between calls, with the
same call count, warmup, and percentile as `bench-iroh`. The recipe is in
`bench/capnp/README.md`, and `bench/capnp/echo.capnp` declares the two calls
every column makes:

- `greet("world")` answers a fixed greeting. It is the smallest message that
  is still a call, so it measures the transport and the protocol turn.
- `report(source, tags, samples, at)` carries one application batch: a name,
  eight tags, sixty-four integer readings, and a timestamp. The server reads
  every reading and answers the count and the sum, so both sides pay for
  the whole message.

For a growth sweep, `bench-iroh --row=report --readings=N` varies the integer
count from zero through 16,384. Use `--frame-cap=1048576` for both codecs:
the default 4 KiB frame limit also sets the producer's admission budget,
which charges the logical value tree before encoding. The output records
both settings. These sweeps use the same handler but are separate from the
fixed sixty-four-reading comparison below.

A growth sweep on 2026-10-15 at commit `afea6a826` used ReleaseFast,
loopback TCP, a 1 MiB frame limit, and three runs per codec with alternating
codec order. Each run measured 3,000 calls after 300 warmups and started
with the machine's one-minute load under 2. The table gives the median p50
in µs.

| Readings | Syrup, one core | Cap'n Proto, one core | Syrup, two cores | Cap'n Proto, two cores |
| ---: | ---: | ---: | ---: | ---: |
| 0 | 9.71 | 9.63 | 13.90 | 13.92 |
| 8 | 9.78 | 9.63 | 13.98 | 13.84 |
| 64 | 10.18 | 9.73 | 14.37 | 14.13 |
| 256 | 11.86 | 10.02 | 16.14 | 14.32 |
| 1,024 | 17.54 | 10.96 | 22.13 | 15.50 |
| 4,096 | 189.89 | 16.32 | 227.54 | 21.41 |
| 16,384 | 726.96 | 43.66 | 863.62 | 43.47 |

In the earlier paired before/after runs, the large Cap'n Proto row fell from
207.04 to 44.75 µs on one core after
`Spill.consume` stopped copying pending bytes onto themselves when an
incomplete frame consumed nothing. The same correction took the Syrup row
from 854.95 to 728.15 µs. Admission, parsing, and memory limits are unchanged.
The two-core Syrup row at 4,096 readings has varied from 197.78 to 229.28 µs
across the paired runs and this refresh, so its small before/after difference
is not a performance claim.

The small calls are close. Cap'n Proto's advantage grows with the integer
batch. Syrup's integer cache is bounded by the frame head, so a run that
outgrows it returns to the general reader. Cap'n Proto keeps borrowing its
words directly from the frame. These round trips also include allocation,
transport, scheduling, and the handler's sum, so the table does not isolate
codec throughput.

Measured 2026-10-15 at commit `afea6a826` on the machine named below, all
four columns in one sitting. Each row pins the threads the same way
(`--pin=5,5` puts both on one core, `--pin=5,6` gives each its own). glowcap
runs each call twice, once under its Syrup codec and once under its Cap'n
Proto codec (`bench-iroh --transport=tcp --row=report --codec=capnp`), so the
right-hand glowcap column carries the message in the same encoding family as
the two Cap'n Proto RPC libraries.

The C++ row runs the reference library. Its bench and generated code are
compiled with full optimization (`-O3`), and the installed Cap'n Proto library
it links keeps its own build settings. The Rust row runs the `capnp-rpc`
crate on a current-thread tokio runtime through the futures compat layer. Each figure is the mean of three p50 values, each run started
only once the machine's one-minute load was under 2. The largest difference
between runs of one row is 0.36 µs, and glowcap's is at most 0.31 µs.

| Recipe | Cap'n Proto C++ 1.1.0 | glowcap `tcp`, Syrup | glowcap `tcp`, Cap'n Proto codec | Cap'n Proto Rust 0.27 |
| --- | --- | --- | --- | --- |
| `greet`, both threads on one core | 10.9 µs | 9.1 µs | 9.1 µs | 19.3 µs |
| `greet`, one core each | 14.8 µs | 13.2 µs | 13.2 µs | 19.6 µs |
| `report`, both threads on one core | 10.9 µs | 10.5 µs | 10.0 µs | 19.4 µs |
| `report`, one core each | 15.1 µs | 14.4 µs | 14.0 µs | 19.0 µs |

The per-value work is complete. Its original target of at most 1 µs extra
for `report` over `greet` on both codecs was not achieved. The work retains
borrowed sends, typed integer runs, cached collection views, and bounded
stream assembly. The growth sweep above records how those paths scale.

The caller lends the sixty-four readings as one typed run. Cap'n Proto
carries them as words, and Syrup parses their decimal text into words in
the frame head. Validation and the handler read the run in place. Under
callgrind, the batch adds about 14,100 caller instructions and 11,700 server
instructions over `greet` on Syrup, and 8,100 and 5,100 on Cap'n Proto.
Syrup's decimal scan and rendering remain part of that difference.

The three harnesses are held to the same shape so the columns compare:

- Every `greet` server answers the same constant greeting and none reads the
  argument. Every `report` server sums the readings it was sent.
- Every client builds the request, sends it, and reads the reply's fields
  inside the timed window, then compares them after the clock stops.
- Every socket has Nagle's algorithm off, every thread pins with the same
  system call, and every harness sorts its samples and reads the same
  percentile index.

What differs is the work each library does on the bytes. glowcap validates
the whole reply at admission, and the two Cap'n Proto readers bounds-check
the one field the client reads.

Both sides park in every row, which is the comparison on equal terms. Under
`strace`, one C++ round
trip makes eight syscalls (two `epoll_pwait`, two `writev`, and four `read`,
two of which return nothing) and one glowcap round trip makes four ring
enters (two submits and two parks). Under callgrind, built for the baseline CPU, one
`greet` round trip runs about 60,000 instructions across both threads in
the C++ reference, 44,000 in glowcap with Syrup, and 42,000 with Cap'n Proto.

## Against Spritely Goblins

`zig build bench-goblins` runs one Racket application on two backends,
[Spritely Goblins](https://spritely.institute/goblins/) and glowcap's Racket
binding over the C ABI. The client and the server are separate Racket
processes on one machine over loopback TCP, and the client sends one call at
a time. Both sides run Racket in both rows, so the gap is the CapTP engine
and not the language. Measured 2026-10-14 on the machine named below, 2,000
samples per suite, two runs. The echo suite is one call round trip. The other
suites (a registry fetch and get, a purse deposit, a task board update) are
several round trips per sample and their Goblins figures moved by a quarter or
more between runs, so only the echo row is a claim.

| Echo round trip | p50 | p99 |
| --- | --- | --- |
| Spritely Goblins | 0.22 ms | 2.3 ms |
| glowcap through its Racket binding | 0.033 ms | 0.09 ms |

## 500,000 live sessions

`zig build bench-peer-scaling -- --live` measures real loopback sockets at
increasing connection counts. The server and load generator are separate
processes with 32 shards each. Each server shard is a `HostRuntime` serving
TCP through a completion resident
([ADR-0202](../docs/decisions/adr/ADR-0202-stream-transports-join-hostruntime-as-a-completion-resident.md)).
Every client signs its own session and fetches a published capability before
the barrier opens, and all sessions stay open while RSS is sampled.

On 2026-10-13, a ReleaseFast run reached 500,000 sessions on Linux
7.0.0-1019-nvidia, aarch64, 20 logical CPUs, 121.7 GiB RAM, and 15 GiB swap,
on the io_uring backend. The server grew from 11,816 KiB to 3,816,584 KiB RSS:
3,804,768 KiB (3.63 GiB) incremental, about 7.6 KiB per session. The
separate load process used 2,890,300 KiB (2.76 GiB). The signed-handshake
and bootstrap-fetch barrier completed in 18.453 seconds, or 36.9 microseconds
per session when amortized across the run. The figure is a same-machine
capacity measurement, not WAN latency.

The connections are plain TCP, so each handshake is signed but the bytes are
not encrypted. The command below runs in its own user and network namespace,
which carries no connection-tracking rules, so the host's tracking table does
not bind the run. It also raises the descriptor limit both processes need,
which the bench does not raise itself.

```sh
unshare -Urn sh -eu -c '
ulimit -n 524288
ip link set lo up
exec zig build -Doptimize=ReleaseFast bench-peer-scaling -- --live --live-max=500000
'
```
