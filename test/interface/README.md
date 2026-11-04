# Interface qualification

Run the generated Tasks and callback paths against independent raw peers.
The [roadmap](../../docs/roadmap.md) item on interface definitions owns status
and remaining work. The [contract reference](contract.md) owns the description
format, target mappings, and acceptance cases.

## Sources

| Path | Responsibility |
| --- | --- |
| `contracts.syrup` | Authored Tasks, shared Loam, and callback definitions |
| `compounds.syrup` | Independently authored list and tuple reply shapes |
| `messages.syrup` | Independently authored expected messages |
| `check_fixtures.py` | Canonical encoding and fixture integrity using the pinned upstream Syrup reader |
| `rust/` | Standalone consumer crate with Tasks, refusal, and callback scenarios |
| `typescript/` | Scalar, compound, callback, and promise-assimilation scenarios |
| `generated/` | Emitted clients, the fixed direct receiver, and independent message constants |
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

The presence fixture distinguishes no arguments from one void argument on the wire
on both profiles. It checks required and optional undefined inputs, optional
text and references, invalid holes, wrong inputs and replies, and remote breaks.
Expected arguments come from the independent message fixture in both languages.

The scalar source in `authoring/scalars.interface` generates Rust and TypeScript
callers. Independent raw peers check exact scalar categories and values on both
profiles. Required and optional calls and tells cover booleans, bytes, bounded
bytes, symbols, float64, and fulfilled errors. Wrong replies, unchanged remote
breaks, float edge cases, and local byte-limit refusal are exercised too.
The existing strict consumer check compiles each method on its own, so unused
helpers cannot hide behind another selected method.

The generated Zig direct receiver accepts exactly two passable values and an
undefined result. Raw callers on both profiles send whole lists, including
leading symbols that the actor API peels into a verb. The receiver restores
that first value before invoking the handler. The same wire list reaches a
separate named receiver as a control. Wrong arity and failed argument projections are
refused before handler entry, and a local payload remains borrowed in place.

The real Rust Board.join and Board.lists methods use five generated reads.
The application proof reads the actual Tasks server. Independent raw peers on
both profiles check text byte limits, count limits, wrong types, unchanged
breaks and raw settlement, and invalid indices without sending. Signed-64-bit
maximum is admitted as an Index, leaving membership to the application.

Tasks' Zig handlers also use generated checks for all six reads. Real server
calls reject extra, missing, wrong-type, and negative arguments, then continue
serving valid requests. Nonmember indices retain the application's NoSuchEdge
result. Scalar tests cover byte/count limits, invalid UTF-8, and borrowed slice
identity. The schema owns the server's name and capacity maxima.

The Rust compound proof checks empty and nonempty lists, list bounds, positional
tuples, retained references, and unchanged raw settlement.
The actual Watcher meets a raw board on both asserted negotiated profiles.
It refuses wrong observation tags, arity, cursor sizes, booleans, and notices,
then continues with its previous cursor. Failed initial polls cancel once,
and a cancellation failure retains the primary poll error.

Generated observation results preserve
unknown and duplicate notices and opaque descriptions containing references.

TypeScript raw peers on both profiles exercise the same compound schemas and
Loam observation reply. They check category, tag, arity, byte/list bounds,
unknown duplicate notices, opaque capabilities, raw observer independence, and
original object identity. Malformed cursor inputs refuse before sending.

Isolated strict Rust and TypeScript consumers compile each compound method independently.
Harness-only child tests call the actual emitted private decoders with small
work/depth budgets and check moved cursor and symbol buffer identity.
TypeScript scratch modules call the emitted private helpers for work/depth
limits and minimum element work, without constructing giant transport replies.
An opaque value exceeding the decoder work budget still passes without traversal.

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
zig build test -Dtest-layer=actors -Dtest-filter="generated direct receiver"
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
