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

The Rust Tasks scenario consumes the application's generated interface. Tasks
and prepared pending arguments share one receipt helper. The raw receipt actor
checks capture, replay, cancellation, cross-Host refusal, and data, capability,
and broken outcomes on both profiles. Binding tests check retained-reference
retirement while the session stays usable. Actor teardown follows the Port's
separate export root.

Generated Rust and TypeScript callers distinguish positional invocation, empty-symbol
methods, and named methods on both profiles. Rust checks that the positional
tell carries no answer authority.

The callback matrix holds the factory reply open through admission and checks
wrong fulfillment, remote break messages, and independent raw observation.
Rust drops both unobserved handles and polled observations while retaining the
argument. TypeScript cancels with original, repeated, and pipelined observations
active. Shared pair fixtures assert the negotiated profile and own cleanup.

Expected message constants come from `messages.syrup`, never from the interface
definitions under test. A `fixture:ref` value is a substitution slot for a
Host-owned reference, never a transmitted value.

## Commands

Run from the repository root through `.agents/skills/work/bin/glowcap-dev`.

```sh
zig build gen-interface-fixtures
zig build gen-interface-fixtures-check interface-test interface-fixtures-check
zig build interface-conversation-check
zig build interface-goblins-check
zig build tasks-app-test
```

The generator check detects stale output. `interface-test` covers description
validation, truncation, literals, and allocation-failure cleanup.
`interface-conversation-check` runs Rust and TypeScript against raw behaviors.
`tasks-app-test` retains the application's independent server tests.

`interface-goblins-check` needs the pinned Goblins installation and runs two
Syrup/V1.0 conversations. Generated Rust Carol receives Bob's greeter through
Goblins Alice, pipelines a positional call, and checks its exact reply and
canonical capability identity. A plain Goblins caller drives the real Tasks
server through its generated Zig argument checker, then checks callable results,
receipt replay, invalid text refusal, and a valid call after refusal.
The existing Host and Loam owners manage capability export and mutation.

Finite process deadlines bound both conversations. The Rust recipient stops and
joins its Goblins host after success or failure. The shared Tasks supervisor
stops the server and removes its temporary store. The Goblins caller uses the
raw Goblins API, while the Tasks server uses its existing generated argument
checker and Loam reply owner. This proves that server boundary without adding
a general generated server adapter.
