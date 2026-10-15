---
id: ADR-0247
status: accepted
date: 2026-10-14
tags: [driver, c-abi, capnp, memory, performance]
decision: "The Host's value gains an `integers` arm, a slice of 64-bit integers that is the list of those integers. It projects as a run-backed view, so a send certifies, measures, and encodes it as one leaf: the Cap'n Proto profile writes its words and Syrup renders its digits, with no per-element projection. The C value carries it as `GLOWCAP_ARG_INTEGERS` with the words behind `bytes`. A received list of integers still materializes as a list of integer values."
supersedes: []
superseded_by: []
amends: [ADR-0243]
amended_by: []
---

# ADR-0247 A caller lends a typed integer run

## Context

A list of integers rides the Cap'n Proto wire as a run of words, and a
handler takes the run as a slice (ADR-0243). A caller's values reach the
wire as a view sequence the engine walks in place (ADR-0246), and each
value is projected to a view where it is read. On the `report` call, whose
64 samples are integers, every sample was projected three times a send,
once by certification, once by the encoder deciding the list is a run, and
once by the write, and those projections cost about what building the
owned tree had cost: the Cap'n Proto caller measured about 31,000
instructions a round trip over `greet`, against 19,000 on the owned path.

## Decision

`driver.Value` (`src/driver/core/value.zig`) gains `integers`, a
`[]const i64` whose meaning is the list of those integers. The projection
(`src/driver/core/value_views.zig`) lends it as a run-backed `list` view on
a little-endian host, the same backing the decoder gives a received run,
so the session measures it as a run, the Cap'n Proto encoder writes its
words as they lie, and Syrup renders each digit string from the slice. On
any other host the slice projects one element at a time through the same
table as a list, and the wire bytes are the same either way, because an
all-integer list already encodes as a run on Cap'n Proto and as a list on
Syrup.

Every other reader treats the arm as the list it is: the owned path lowers
it into integer arguments when a tree carries a capability or goes to a
local actor, the boundary copy and the promise clone copy the slice, and
the capability scan passes over it.

The C value (`src/c_abi/shared/value.zig`) carries the arm as
`GLOWCAP_ARG_INTEGERS`: `bytes` points at the first `int64_t` in host byte
order and `bytes_len` is the byte length, so the layout every archive
shares is unchanged. A pointer that is not 8-aligned or a length that is
not a multiple of 8 is refused as `UnsupportedValue` before anything is
queued, the way a noncanonical big integer is.

## Scope (what this does not decide)

A received list of integers still materializes as a `list` of `integer`
values, and a handler that wants the words takes them from the run
(`driver.Args.integers`). `model.Argument` gains no arm: the run stays a
view backing and a Host value, never a model shape. Each binding accepts its typed integer array: a Rust
`Argument::Integers(Vec<i64>)`, a Python `array.array('q')`, a TypeScript
`BigInt64Array`, and a Racket `s64vector`.

## Alternatives Considered

- **Recognize an all-integer `list` of values and lend it as a run.**
  Rejected: the values are not words in memory, so the recognition is
  itself a projection of every element.
- **A dedicated pointer field on `GlowcapArgument`.** Rejected: it changes
  the layout every archive shares, for a pointer `bytes` already carries.
- **Keep per-element projection and make it cheaper.** Done first
  (`LazySequence.VTable.next` writes into the walk's room), and it
  recovered about a tenth of the cost. The rest is the projection itself.

## Consequences

- `test/driver/value_views_test.zig` holds that the arm projects as a run
  and that a list of integer values does not. `test/c_abi/host/values_test.zig`
  holds the C round trip and the ragged-length refusal.
- The `report` bench row lends its samples as this arm, which is the form
  the Cap'n Proto reference columns already use.
- Review against `1af47450c`, including the boundary fixes, measured these
  caller instructions per round trip:

  | Row | Base | Reviewed |
  | --- | --- | --- |
  | `report`, Cap'n Proto | 40,610 | 34,698 |
  | `report`, Syrup | 48,207 | 40,290 |
  | `greet`, Cap'n Proto | 23,328 | 23,583 |
  | `greet`, Syrup | 23,944 | 24,148 |

  Both builds used ReleaseFast, `-Dcpu=baseline`, and TCP. Callgrind
  separated the caller and server threads. Subtracting smoke from full
  and dividing by 3,050 calls removes setup (the method in `bench/README.md`).
  The report server measured 24,999 → 25,091 instructions on Cap'n Proto
  and 48,433 → 48,611 on Syrup. The small call costs roughly 1% more.
  The report saves about 9% and 8% across both threads respectively.
- Five alternating ReleaseFast runs of each build, pinned to CPUs 0 and 1,
  measured median mean report latency of 36.44 → 34.99 µs on Cap'n Proto
  and 40.25 → 38.98 µs on Syrup. Those are local TCP measurements, about
  4% and 3% lower, with overlapping run ranges. They are not a claim about
  real-network latency.
- The first review profile found Syrup still projecting every word through
  a generic argument. Its encoder now reads run words directly into the
  shared integer writer, in both measure and fill passes. Byte-equivalence
  tests cover empty runs, unaligned bytes, and signed 64-bit extremes.
