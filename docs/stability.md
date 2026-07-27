# What you can depend on

pancake is one library with a lot of surface: five transports, four language
bindings, two codecs, and a C ABI under all of them. Those pieces are not
equally proven, and saying so plainly is more useful to you than a single
badge would be.

This page gives every pluggable piece a support tier. A tier here is not a
judgement about how finished the code looks. It is the answer to one question:
**what runs automatically to prove this still works, and who wrote the thing it
is proved against?** If nothing runs, the tier is low, however good the code
is.

Read this alongside [docs/boundaries.md](boundaries.md), which records where
each capability stops, and [docs/community-review.md](community-review.md),
which lists what each individual check does and does not prove.

## At a glance

The whole page in one table. The tier definitions are just below, and the
site's stability page carries this same table; `zig build meta-check` holds
the two copies identical.

| Piece | Tier |
| --- | --- |
| The protocol core (model, codec, session, engine) | 1 |
| Syrup codec | 1 |
| `tcp` transport | 1 |
| `iroh` transport | 1 |
| Cap'n Proto codec | 2 |
| `keyed-tcp` and `inproc` transports | 2 |
| The actor layer and the persistent map (its snapshot store) | 2 |
| The Rust, TypeScript (Deno), Python, and Racket bindings | 1 |
| The TypeScript binding on Bun | 2 |
| C ABI | 2 |
| The relay, in all four runtimes | 2 |
| `webrtc` transport | 3 |
| Browser (`wasm32`) | 2 |
| macOS | 3 |
| Windows | not implemented |
| Mutation fuzzing | 2 |

## The tiers

**Tier 1 — proved against somebody else's code, on every push.** At least one
of the checks behind this row talks to an implementation pancake does not
control: the upstream OCapN test suite, a live Spritely Goblins vat, the
upstream Syrup encoder, or a real iroh network. If pancake drifts away from what those implementations
speak, one of them notices without anyone remembering to look. Where the
implementations disagree with the draft text,
[`conformance/ocapn-findings/`](../conformance/ocapn-findings/README.md) pins
the discrepancy instead.

**Tier 2 — proved on every push, against pancake's own code.** The checks run
automatically and a break is caught before it ships, but every party to them is
pancake. They prove the pieces agree with each other. They cannot prove the
whole agrees with the specification.

**Tier 3 — a proof exists, but nothing runs it for you.** There is a real check
in the tree and you can run it yourself; it is not wired into continuous
integration. Expect the surface to work. Do not expect a regression to be
noticed quickly.

**Not implemented.** Named here when the absence is easy to mistake for a
feature. A surface left off this page entirely would read as endorsed, so
anything that looks like coverage and is not gets a row saying so.

These tiers describe the checks configured in the [mirror workflow](https://github.com/jimisaacs/pancake/actions/workflows/check.yml). They are
current evidence only when that workflow is green for the commit being
evaluated.

This page does not promise API stability: no type, function, or wire detail
here is frozen, and no version carries a compatibility guarantee. A tier is not
a security claim either; unreviewed code is unreviewed code at every tier.
[PROVENANCE.md](../PROVENANCE.md) covers how the code is written.

## What runs on every push

Everything below is scored against this list, which is the exact set of checks
[`ci/gates.sh`](../ci/gates.sh) runs. `zig build meta-check` compares the two,
so this list cannot quietly fall behind the sequence it describes.

<!-- ci-gate-list:begin -->
- `zig build check`
- `zig build fuzz`
- `zig build iroh-sidecar-test`
- `zig build webrtc-sidecar-test`
- `zig build bindings-fmt-check`
- `zig build bindings`
- `zig build racket-test`
- `zig build wasm-driver-test`
- `zig build wasm-abi-layout-check`
- `zig build wasm-import-check`
- `zig build goblins-interop`
- `zig build bindings-goblins-interop`
- `zig build bindings-goblins-handoff`
- `zig build bindings-goblins-gift`
- `zig build goblins-handoff`
- `zig build goblins-gift`
- `zig build goblins-gc`
- `zig build deno-goblins-listen`
- `zig build fixture-gen-check`
- `zig build ocapn-findings-check`
- `zig build ocapn-conformance`
- `zig build iroh-interop`
- `zig build bindings-relay`
- `zig build bindings-relay-iroh`
<!-- ci-gate-list:end -->

`zig build check` is itself an aggregate: the test suite, the architecture and
scaffolding checks, the public examples, the protocol reference fixtures, and
the allocation and footprint budgets. A row that cites it is covered by
whichever of those applies.

## The protocol core

The four layers that are the protocol, plus the actor layer above them.

| Component | Tier | What proves it | What would raise it |
| --- | --- | --- | --- |
| `ocapn/model`, `ocapn/codec`, `ocapn/session`, `ocapn/engine` | 1 | `ocapn-conformance` runs the upstream OCapN suite against a pancake peer; `goblins-interop`, `goblins-handoff`, and `goblins-gift` hold live conversations with a real Goblins vat in both directions, with handoff as gifter and as recipient | — |
| `actors` (vat, turn loop, local time-travel) | 2 | `check` covers the turn loop, hosting over the engine, and snapshot/restore | Nothing outside pancake implements this layer, so tier 1 is not reachable; it is a Zig-native layer above CapTP, not a protocol surface |
| `persistent` (refcounted HAMT) | 2 | `check` covers structural sharing, refcounts, and leak-freedom | Same: a leaf data structure with no outside counterpart |

## Codecs

| Codec | Tier | What proves it | What would raise it |
| --- | --- | --- | --- |
| Syrup | 1 | `fixture-gen-check` regenerates the whole fixture corpus with the *upstream Racket Syrup encoder* and diffs it against the committed bytes, so a divergence from upstream fails the build | — |
| Cap'n Proto | 2 | `check` covers encode/decode fixtures and per-arm cross-codec equivalence against the Syrup path | A cross-check against an outside Cap'n Proto implementation. pancake writes the wire form by hand rather than through capnp's own tooling, so nothing currently tests that reading |

## Transports

A netlayer is a locator transport symbol. CapTP itself never names a transport.

| Transport | Tier | What proves it | What would raise it |
| --- | --- | --- | --- |
| `tcp` | 1 | `ocapn-conformance` and the three Goblins steps all run over TCP, so every push carries a live conversation with somebody else's implementation on this transport | — |
| `iroh` | 1 | `iroh-interop` holds an OCapN session between two pancake peers over real iroh endpoints, and `bindings-relay-iroh` dials a live iroh endpoint through every runtime's relay. The QUIC stack under both is iroh's, not pancake's | — |
| `keyed-tcp` | 2 | `check` covers the restart proof: happy path, squatter refusal, and same-seed restart on a fresh port | `bindings-keyed-tcp-restart` in CI would add the four bindings; no outside implementation speaks this symbol, so tier 1 rests on a partner adopting it |
| `inproc` | 2 | `check` covers the in-process netlayer end to end | Nothing outside a single process can speak this transport, so tier 2 is its ceiling by construction |
| `webrtc` | 3 | `webrtc-resident-check` type-checks the resident on every push, and that is all that runs. The DataChannel proofs (`webrtc-interop`, `webrtc-mesh`, `webrtc-handoff`, `webrtc-browser-peer`, `webrtc-browser-to-browser`) are real and pass, but only when run by hand | Wiring the DataChannel proofs into `ci/gates.sh`. They need a Rust sidecar build and a headless Chromium, which is why they are not there yet |

## Language bindings

Every binding consumes the C ABI. None of them is the authority for Zig
semantics.

| Binding | Tier | What proves it | What would raise it |
| --- | --- | --- | --- |
| C ABI (`libpancake_ocapn`, `libpancake_driver`, transport archives) | 2 | `check` holds header parity by compiling the generated headers, plus the layout and ownership tests; all five dogfoods run on every push | The C ABI is proved by pancake's own consumers. An outside C consumer, or the OCapN suite driven through the ABI rather than through Zig, would reach tier 1 |
| Rust | 1 | A live keyed conversation with a real Goblins vat through the binding itself, in both handoff roles (`bindings-goblins-interop`, `-handoff`, `-gift`), plus `rust-dogfood` and the Rust relay rows | — |
| TypeScript (Deno) | 1 | The same three live Goblins checks, plus `deno-dogfood`, the three `wasm-*` checks for the browser peer, and the Deno relay rows | — |
| TypeScript (Bun) | 2 | `bun-dogfood` exercises the shared TypeScript source against pancake. The live Goblins clients run under Deno, not Bun | A Bun-native live Goblins client |
| Python | 1 | The same three live Goblins checks, plus `python-dogfood`, the Python relay rows, and `ruff` and `mypy` under `bindings-fmt-check` | — |
| Racket | 1 | The same three live Goblins checks, plus `racket-dogfood`, the Racket relay rows, and `racket-test` for the unit tests | — |

Deno, Python, Rust, and Racket reach tier 1 because each holds its own
conversation with a real Goblins vat rather than inheriting the Zig core's
proof. Bun exercises the same TypeScript source, but its runtime path is proved
only against pancake.

## Relays

The relay is what lets a browser peer reach a native one. Each runtime ships
its own; the contract is one shared harness, so no runtime can quietly lack a
proof.

| Relay | Tier | What proves it |
| --- | --- | --- |
| Deno (reference), Python, Rust, Racket | 2 | `bindings-relay` runs TCP forwarding, the backpressure clause, and the idle-timeout clause against every runtime through one harness; `bindings-relay-iroh` adds the iroh leg |

## Platforms

| Platform | Tier | What proves it |
| --- | --- | --- |
| Linux (x86-64, aarch64) | 1 | Every check above runs here, including the io_uring completion backend |
| Browser (`wasm32-freestanding`) | 2 | `wasm-driver-test` holds a keyed handshake from JavaScript, `wasm-abi-layout-check` and `wasm-import-check` hold the ABI seam |
| macOS | 3 | `cross-check` compiles the full library for macOS with the kqueue backend on every push. Nothing runs it. The kqueue backend has never executed in CI |
| Windows | Not implemented | There is no IOCP completion backend |

## Hardening

| What | Tier | Where it stands |
| --- | --- | --- |
| Hostile-input tests | 2 | `check` runs the hand-built frames that no encoder can emit: an aliasing composite DAG, an aliasing hint list, single-byte corruption of valid frames. Each one refuses in bounded time |
| Mutation fuzzing | 2 | `zig build fuzz` runs coverage-guided mutation fuzzing over every surface that takes bytes somebody else chose. That is both codecs' framers and decoders, the whole inbound path from stream to application events, and the byte-fed host at read boundaries the fuzzer picks. It also covers blocking frame reads through the spill that carries a frame across two reads, handoff give parsing, and locator parsing. Most targets check more than crashes: a decoded message must survive a re-encode and decode unchanged, and a session must keep every table inside the limit it declares, checked after each step against caps set low enough to cross. Each target searches on its own and must advance the fuzzer's run counter to count, so one that stops working fails the sweep by name. `zig build meta-check` refuses a target the search would not find, and holds each seed list against the corpus directory. It runs on every push. Anything it finds becomes a saved input in that target's `fuzz_regressions/` that `check` replays from then on |

Zig's own test runner does not compile in fuzz mode in this release, so
pancake vendors it with one call renamed; `zig build meta-check` compares the copy against the toolchain and will
tell you to delete it the day Zig fixes the bug. `zig build --fuzz` also reports
success even when it finds a crash, so the step does not trust that exit code:
it looks for the saved input, and refuses to pass a run that never searched
anything.

Two of the targets check against something outside pancake. The persistent map
runs alongside the standard library's hash map, which answers every lookup
independently, so a refcount slip in the trie shows up as a disagreement rather
than as silence. The actor target keeps its own record of what each actor held
when each snapshot was taken and restores old snapshots against it at the end.

The rest hold pancake's expectations to pancake. A decoded message has to
survive two crossings unchanged. A session has to keep every table inside the
caps it declares, checked after each step against caps deliberately set low
enough for a short program to cross. A relayed handoff span has to stay inside
the bytes it was found in, and a locator has to read back what it wrote.

What is outside pancake in all of them is narrower than it sounds, and worth
naming exactly: the inputs, which nobody chose, and the fault detectors, which
are Zig's safety checks and the testing allocator's leak accounting. A leak
report is not this project's opinion. Every expectation above it was written
here.

It has found nothing so far. Coverage sits around 11% for the engine target and
16% for the byte-fed host; the persistent map reached 22.8% over 1.7 million
runs. So the sweep says that a few hundred thousand mutations per target reached
no memory fault, no leak, and no stated property, over roughly a tenth of the
code they could reach. It says nothing about the rest, nothing about a decode
that is well-formed and wrong, and nothing about agreement with the
specification. That last one is what `ocapn-conformance` and the Goblins steps
are for.

## Raising a tier

The work is the same shape every time: find the proof that exists but is not
wired in, wire it in, and move the row. The four highest-value moves on this
page today, in order:

1. A macOS runner. The kqueue backend is compiled on every push and executed on
   none, which is the widest gap between "builds" and "works" in the tree.
2. The WebRTC DataChannel proofs into CI. One transport moves from tier 3 to
   tier 2.
3. An outside Cap'n Proto implementation reading pancake's frames. One codec
   moves from tier 2 to tier 1.
4. A deep fuzz run with a corpus that survives it. Every sweep today is the
   per-push budget, and the accumulated corpus starts from nothing each time, so
   the search never compounds. A scheduled run with that corpus cached is what
   turns a standing sweep into a search.

If you are evaluating pancake and a tier matters to you, the fastest way to
change it is to say so; a surface with a user gets its proof wired in first.
