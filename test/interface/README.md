# Interface qualification

Run the generated Tasks and callback paths against independent raw peers.
The [roadmap](../../docs/roadmap.md) item on interface definitions owns status
and remaining work. The [contract reference](contract.md) owns the description
format, target mappings, and acceptance cases.

## Sources

| Path | Responsibility |
| --- | --- |
| `contracts.syrup` | Authored Tasks, shared Loam, and callback definitions |
| `messages.syrup` | Independently authored expected messages |
| `check_fixtures.py` | Canonical encoding and fixture integrity using the pinned upstream Syrup reader |
| `rust/` | Standalone consumer crate with Tasks, refusal, and callback scenarios |
| `typescript/` | Callback and promise-assimilation scenarios |
| `generated/` | Emitted callback clients and independent message constants |
| `run.ts` | Starts the Tasks server and runs the Rust proof with bounded lifetime and cleanup |

The Rust Tasks scenario consumes the application's generated interface. Callback
projections are self-contained and share their helper template with Tasks.
Expected message constants come from `messages.syrup`, never from the interface
definitions under test. A `fixture:ref` value is a substitution slot for a
Host-owned reference, never a transmitted value.

## Commands

Run from the repository root through `.agents/skills/work/bin/glowcap-dev`.

```sh
zig build gen-interface-fixtures
zig build gen-interface-fixtures-check interface-test interface-fixtures-check
zig build interface-conversation-check
zig build tasks-app-test
```

The generator check detects stale output. `interface-test` covers description
validation, truncation, literals, and allocation-failure cleanup.
`interface-conversation-check` runs Rust and TypeScript against raw behaviors.
`tasks-app-test` retains the application's independent server tests.
