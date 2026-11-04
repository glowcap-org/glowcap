# Interface generation

Build-time generation from the authored Syrup fixtures. The
[roadmap](../../docs/roadmap.md) item on interface definitions owns scope and
progress. The [proof suite](../../test/interface/README.md)
owns executable qualification.

| Source | Responsibility |
| --- | --- |
| `description.zig` | Bounded Syrup description reader |
| `model.zig` | Declaration validation, method selection, references, and type resolution |
| `calls.zig`, `call_type.zig` | Checked call signatures carrying scalar constraints |
| `zig.zig`, `zig_reads.zig` | Tasks creation and read checks, and the fixed Zig direct receiver |
| `rust.zig` | Tasks creation and read module assembly |
| `callbacks.zig`, `typescript.zig` | Ordinary-call emission from checked signatures |
| `typescript_scalars.zig` | Exact JavaScript scalar guards and byte limits |
| `rust_bounds.zig` | Rust argument checks and deduplicated bounded reply decoders |
| `rust_support.zig`, `templates/` | Reusable helpers, selected from the emitted methods |
| `exports.zig` | Public export validation and isolation from private implementation names |
| `literal.zig` | Source string escaping |
| `expectations.zig` | Test constants from independent message fixtures |
| `generate.zig` | Fixture selection, output paths, and compiler tests |

Emitters receive checked descriptions and write source, and never parse the
authored contract. The generation driver selects each projection's method and
uses the repository's emit/verify harness. The creation projection's names
and Loam receipt verbs are written for Tasks' `add`, so its emitters refuse
any other method.

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
metadata.

Rust consumes owned byte vectors and symbol/error strings,
then moves them into the binding argument. Local refusal drops those inputs.
Reply decoding moves the binding's owned values out without cloning them.

TypeScript preserves the JavaScript objects and checks their categories before
sending. Its byte-length checks add no payload copy. Neither target filters
float64 values. A fulfilled error remains data, distinct from a broken call.

Tasks' Rust creation and read projections share the checked contract.
The [read projection](../../test/interface/contract.md#tasks-rust-read-projection)
owns the bounds and target coverage.

Generated helpers delegate promise and reference ownership to the bindings.
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
