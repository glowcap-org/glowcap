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

`interface-goblins-check` runs two tests against the pinned Goblins version.
A generated Rust client receives Bob's greeter from Alice and pipelines a
positional call to it. It checks the reply and verifies that a second
introduction returns the same greeter.

The other test uses Goblins to create a Task and call it. It replays the
creation receipt, checks that invalid text creates nothing, then makes another
valid call. Tasks uses its generated Zig argument checker. Loam creates the
child and builds the capability reply.

Both tests check that the session negotiated Syrup/V1.0. Response waits have
deadlines. The Rust client stops and joins its Goblins process when the test
ends, including on failure. The Tasks supervisor stops its server and removes
the temporary store.
