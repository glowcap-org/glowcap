# Interface generation

Build-time generation from the authored Syrup fixtures. The
[execution plan](../../docs/planning/interface-definitions.md#execution-map)
owns scope and progress. The [proof suite](../../test/interface/README.md)
owns executable qualification.

| Source | Responsibility |
| --- | --- |
| `description.zig` | Bounded Syrup description reader |
| `model.zig` | Declaration validation, references, and type resolution |
| `calls.zig` | Checked ordinary-call signatures |
| `zig.zig`, `rust.zig` | Tasks creation projections |
| `callbacks.zig`, `typescript.zig` | Ordinary-call emission from checked signatures |
| `templates/` | Reusable generated helpers, owned once in source |
| `literal.zig` | Source string escaping |
| `expectations.zig` | Test constants from independent message fixtures |
| `generate.zig` | Fixture selection, output paths, and compiler tests |

Emitters receive checked descriptions and write source. They do not choose
application methods or parse the authored contract. The generation driver
owns that selection and uses the repository's emit/verify harness.
Unsupported projections fail explicitly.

Generated helpers delegate promise and reference ownership to the bindings.
Tasks owns its workflow and the server's policy. Binding changes needed by a
proof belong in the binding and have regression coverage there.

```sh
.agents/skills/work/bin/glowcap-dev zig build gen-interface-fixtures
.agents/skills/work/bin/glowcap-dev zig build gen-interface-fixtures-check interface-test
```
