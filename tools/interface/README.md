# Interface generation

Tasks and callback generation use the complete authored text bundle, checked
against independent Syrup fixtures. The
[roadmap](../../docs/roadmap.md) item on interface definitions owns scope and
progress. The [proof suite](../../test/interface/README.md)
owns executable qualification.

| Source | Responsibility |
| --- | --- |
| `description.zig` | Bounded Syrup description reader |
| `model.zig` | Declaration validation, method selection, and arena-owned normalized type graph |
| `calls.zig`, `call_type.zig` | Checked call signatures and immutable compound types |
| `zig.zig`, `zig_reads.zig` | Tasks creation and read checks, and the fixed Zig direct receiver |
| `rust.zig` | Tasks creation and read module assembly |
| `callbacks.zig`, `typescript.zig` | Ordinary-call emission from checked signatures |
| `typescript_scalars.zig` | Exact JavaScript scalar guards, bigint bounds, and UTF-8 byte limits |
| `compound_graph.zig` | Bounded target-neutral graph traversal and minimum decoder work |
| `typescript_compounds.zig` | Validated views of existing list, tuple, and tagged-record replies |
| `rust_compounds.zig` | Owned list, tuple, and tagged positional-record reply decoders |
| `rust_bounds.zig` | Rust argument checks and deduplicated bounded reply decoders |
| `rust_support.zig`, `templates/` | Reusable helpers, selected from the emitted methods |
| `exports.zig` | Public export validation and isolation from private implementation names |
| `literal.zig` | Source string escaping |
| `text.zig`, `text_parser.zig`, `text_encode.zig` | Pure module compilation, cached headers and bounded canonical encoding |
| `text_loader.zig` | CLI-owned rooted file loading and compilation cache |
| `authored.zig` | Pinned complete Tasks, Loam and qualification source bundle |
| `expectations.zig` | Test constants from independent message fixtures |
| `generate.zig` | Fixture selection, output paths, and compiler tests |

Emitters receive checked descriptions and write source, and never parse the
authored contract. The generation driver selects each projection's method and
uses the repository's emit/verify harness. The creation projection's names
and Loam receipt verbs are written for Tasks' `add`, so its emitters refuse
any other method.

Text compilation returns canonical bytes and the checked Model over the original
source nodes. Consumers reuse that Model through emission. The compilation arena
and source bytes outlive it. Untrusted Syrup input is read and validated once.

Rust also projects a receipt with one `promise<value>`
argument and a void result. Its preparation retains through the binding before
sequence acquisition. Tasks and this projection share the request/replay
helper. Unsupported projections fail explicitly.

Ordinary Rust and TypeScript calls preserve trailing optional arguments and
explicit undefined values. Omission shortens the argument list. Rust refuses a
missing argument followed by a present one, and TypeScript checks arity and
value types before sending. Contract null remains an unsupported target type.

Rust and TypeScript calls and tells also project booleans, bytes, symbols,
float64, and fulfilled error values. Byte bounds count bytes and retain their
normalized `u64` limits. The description reader admits signed-64-bit integer
metadata. TypeScript preserves arbitrary bigint values and applies normalized
integer and text bounds in both directions, including nested replies. Text
validation counts UTF-8 bytes without allocating encoded payloads.

Rust consumes owned byte vectors and symbol/error strings,
then moves them into the binding argument. Local refusal drops those inputs.
Reply decoding moves the binding's owned values out without cloning them.

TypeScript preserves the JavaScript objects and checks their categories before
sending. Its byte-length checks add no payload copy. Neither target filters
float64 values. A fulfilled error remains data, distinct from a broken call.

Text source describes lists, tuples, positional records and single-payload tagged
values through the same checked model as Syrup input. A tagged tuple stays one
payload. String-keyed structs, maps and unions remain unsupported.
Rust and TypeScript reply projections support these containers, including empty tuples and records.
`Model.init` requires a caller-owned arena that lasts through emission.
Named aliases share immutable normalized nodes.

Shared graph admission limits expanded
inline structure to <!-- value compound_graph.zig max_inline_structure -->256<!-- /value -->
units per emitted type, including list element helpers. Tuple/record containers
and their inline fields are counted, with each scalar or list slot counting once.
This compiler resource limit prevents excessive Rust value and future layouts.
It is separate from schema cardinality and is not a Rust byte-size estimate.

Alias cycles are invalid,
and productive copied recursion remains an explicit projection refusal.
Compiler work and effective depth include alias expansion.

Rust type exports are explicit rows pairing an API name with a normalized type.
The existing export validator checks those names against calls and support.
Tasks selects `LoamObservation`, a public tuple struct with positional fields.
Its Watcher calls generated `Receiver.poll` and commits the moved cursor only
after the whole reply passes. `Board.join_with_runtime` consumes a configured
Runtime when the caller needs to select its Host or transport configuration.

If initial polling fails after observe commits, Watcher attempts cancellation
before returning the poll error. A cancellation failure adds cleanup context
while preserving the primary poll error. Dropping references does not retire
Loam's durable observation context.

Rust typed lists reserve one result vector after schema and decoder-work checks
when their elements have a different layout from `Argument`. A `list<value>`
already has the projected `Vec<Argument>` layout and returns that buffer directly. Payloads and references move into results.
Opaque `value` fields move intact without decoder traversal. The decoder's
work limit returns `ResourceLimit`, separately from a wrong reply category.

TypeScript exposes readonly, passable sequence views over the existing arrays
or local packed integer runs. Tagged payloads retain their actual array shape.
Validation returns original objects, payloads, and capability wrappers. Its single temporary
work counter dies after each observation. Shape failures throw `TypeError`, and
decoder exhaustion throws exported `ResourceLimit`, without changing raw
settlement. The [compound mapping](../../test/interface/contract.md#typescript-compound-replies)
owns its representation, ownership, and target refusals.

Tasks' Rust creation and read projections share the checked contract.
The [read projection](../../test/interface/contract.md#tasks-rust-read-projection)
owns the bounds and target coverage.

Generated helpers delegate promise and reference ownership to the bindings.
TypeScript handles select `RemotePromise.withGc` before observation, preserving
the [shared raw views and borrowed local results](../../test/interface/contract.md#typescript-compound-replies).
Tasks owns its workflow and the server's policy. Binding changes needed by a
proof belong in the binding and have regression coverage there.

```sh
.agents/skills/work/bin/glowcap-dev zig build gen-interface-fixtures
.agents/skills/work/bin/glowcap-dev zig build gen-interface-fixtures-check interface-test
```

The Zig server checks exact read arity and the declared Index range before
asking ContentCall to disclose a child. Scalar replies check counts and text
byte limits. Stored text receives one UTF-8 scan up to its declared byte maximum.
The reply borrows that payload through the hosting turn.
Loam still owns capability disclosure and export.
