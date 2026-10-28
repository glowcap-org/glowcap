# Interface description and fixture contract

The authored [Syrup description](contracts.syrup) defines the Tasks and callback
corpus. This reference specifies its encoding, mappings, and acceptance cases.
The [execution plan](../../docs/planning/interface-definitions.md) owns progress
and the order in which those cases are qualified.

## Description version 1

A description is one canonical Syrup record:

```text
<glowcap:interface 1 profiles definitions>
```

The notation here omits Syrup length prefixes. The record label is a symbol.
`profiles` maps strings to integer versions. `definitions` maps fully qualified
names to declarations. All referenced definitions are included: imported
libraries resolve into this graph, without machine paths or ambient lookup.

This bundle authors the shared Loam definitions once, and Tasks references them.
A future text frontend produces the same graph instead of adding a second
maintained source.

| Record | Fields in order |
| --- | --- |
| `type` | Type expression |
| `interface` | Method dictionary |
| `method` | Ordered parameter list, result type, convention symbol |
| `parameter` | Source name string, type, optional boolean |
| `rest` | Source name string, element type |
| `ref` | Fully qualified definition name string |
| `bounded` | Type expression, dictionary of integer bounds |
| `list`, `set`, `promise` | Element or fulfillment type |
| `tuple`, `union` | Ordered list of member types |
| `map` | Key type, value type |
| `struct` | Field dictionary, extension type or false for closed |
| `field` | Type, optional boolean |
| `tagged` | Exact tag string, one payload type |
| `record` | Exact tag string, ordered positional field types |
| `literal` | One string, symbol, integer, or boolean |

Primitive type expressions are symbols: `undefined`, `null`, `bool`, `integer`,
`float64`, `string`, `bytes`, `symbol`, `target`, `value`, `error`, and the
profile forms `keyword` and `float32`. A type name is always a `ref`, never an
ambiguous primitive spelling. A `struct` represents string-keyed copied data, while
`record` represents the existing binding's tagged positional record. It does
not imply arbitrary-label Syrup support. `tagged` has exactly one payload
position, even when that payload is a tuple.

Method keys are exact wire names as strings. False denotes direct invocation.
Empty string is a valid named method and differs from false. The current
[actor API loses that distinction](../../docs/boundaries.md#invocation-shape),
so that target qualification case remains unmet.

Conventions are
`call`, `tell`, and `loam.receipt`. A tell result must be `undefined`, denoting
no result channel. A receipt method must be named.

Required parameters precede optional parameters. Absence is a shorter argument list, never null or void.
A final `rest` parameter record holds a source name and element type. It cannot
follow optional parameters. It accepts the remaining arguments without wrapping
them in a list.

Bounds are `min`, `max` for integers, `min_bytes`, `max_bytes` for strings and
bytes, and `max_items` for containers. A bounded container wraps its type expression
instead of a primitive symbol. String limits count UTF-8 bytes. Reject unknown
records, profiles, fields, conventions, unresolved names, contradictory bounds,
ambiguous unions, and unproductive alias cycles. Recursive copied structures
may contain references to themselves, but runtime copied values must be acyclic.

Before emission, limit input to 1 MiB, 4,096 definitions, 65,536 graph nodes,
64 nested type constructors, 256 parameters per method, and 16 MiB of output
per target. These are initial compiler resource ceilings, not OCapN limits.
Graph validation needs a visited set and explicit work budget. Canonical input
is still untrusted. Reject duplicate dictionary keys while parsing, because decoding
into an overwriting map is insufficient. The upstream fixture reader is used
only on repository-owned inputs and is not the proposed production parser.

`glowcap.values: 1` names the local target mapping below, and `loam.receipt: 1`
names the existing preparation convention. They are build requirements, not
wire negotiation or community profile names. The two supported session profiles
remain `1.0` and `glowcap-next`. A description cannot change a live session.

## Tasks and shared Loam

| Receiver | Method → public result |
| --- | --- |
| Board | `lists() → ListCount`, `list(Index) → TaskList`, `add-list(Name) → TaskList` |
| TaskList | `name() → Name`, `count() → TaskCount`, `task(Index) → Task`, `add(Text) → Task`, `move(Task, TaskList) → TaskCount` |
| Task | `text() → Text` |
| Receipts | `mutation-sequence() → Sequence` |
| Observable | `observe() → Registration`, `observe-live(Identity) → Registration` |
| Receiver | `poll(Cursor?) → Observation`, `receive(Cursor?) → Observation` |
| Canceller | `cancel() → bool` |

Names contain 1–64 bytes, and text contains 1–4,096 bytes. List counts are 0–16, and
task counts are 0–256. An index is a nonnegative signed-64-bit integer, but
actual membership is server policy. Sequence is 1 through signed-64-bit max,
the current public driver integer range, even though storage uses `u64`.
Identity is 16 bytes and cursor is 56 bytes.

`add-list`, `add`, `move`, `observe`, and `observe-live` use receipts. For example,
creation first calls `[symbol("mutation-sequence")]`, then submits
`[symbol("mutate"), sequence, string("add"), string("write tests")]`.
The public result is a Task capability. The handler's internal void result
must not become the generated client result type.

Registration is a two-element list `[Receiver, Canceller]`. Observation is the
five-position record `access:observation`: cursor, description, reset boolean,
changed boolean, notice-symbol list. Description deliberately remains `value`:
this observer reports use or control policy data without imposing a new policy
schema. Notices preserve unknown symbols. Current notices include `access`,
`target`, `inventory`, `management`, and `subtree`.

These are separate views of capabilities, not inheritance or runtime type
casts. Managed use/control endpoints support observation. Dependent facets do
not. Generating an Observable wrapper does not authorize observation. Durable
name, derivation, policy editing, and other management operations remain outside
this Tasks contract and belong to their later migration.

## Generated API and ownership

The following names sketch behavior, not a committed language-specific API:

```text
TaskList(target).prepare_add(text) -> pending preparation of Prepared<Task>
Prepared<Task>.submit()           -> pending Task result
Prepared<Task>.replay()           -> another observation of the same request
Task(target).text()               -> pending string result
Receiver(target).poll(optional_cursor) -> pending Observation result
```

Ordinary calls send immediately. Rust must preserve a passable pending-call
handle instead of hiding transmission inside an `async fn` body. Zig makes
allocator and owning result cleanup explicit. Host-side borrowed parameter
views live only through their hosting turn, and asynchronous retention uses the
existing Host owner. A typed target wrapper expresses an expectation, not
remote introspection or authority validation.

Preparation copies and validates data and retains references **before** it
suspends for sequence acquisition. Submission retains the exact target,
sequence, and snapshot. Replay never acquires a fresh sequence automatically.
Uncertain commit, conflict, expiry, local validation, wrong fulfillment, remote
break, and transport failure remain distinguishable. Unknown break values
remain observable, and declared break cases must not close the error universe.

The callback fixture opens a Reader through Factory, calls Sink.push with it,
and passes a still-pending Reader to Factory.accept. Reader has a wire method
named `then`. Direct and send-only interfaces check selector-free invocation
and absence of a result channel. Qualification must hold the factory reply
pending while admitting the dependent calls. A pre-resolved answer is not proof.

The runtime owns promise, settlement, and listener behavior. The generator
must adapt to its public ownership contract. In particular, independently retained pending
arguments, listener cancellation, repeated observation, and references surviving
answer release need qualification against that owner. ADR-0070 supplies stored
resolution retention. It does not by itself prove a binding exposes every
operation preparation needs. No generator-owned vow registry is permitted.

## Target mapping

Both session profiles use the following current value mapping. The protocol
profile differences concern operations too: `glowcap-next` does not carry
`op:resolve`, `op:get`, `op:index`, or `op:untag`. Runtime-supported operations
are the authority. Emitters must not invent those operations on that profile.

| Contract value | Zig driver / Rust binding | Current mapping or limit |
| --- | --- | --- |
| undefined | `.void` / `Void` | Syrup void record |
| null | neither | Explicit unsupported-target diagnostic, never alias void |
| bool | `.boolean` / `Boolean` | Syrup boolean |
| integer | `.integer`, `.big_integer` / `Integer`, `BigInteger` | Exact signed integer, use big integer outside i64 |
| float64 | `.float64` / `Float` | Binary64, preserve signed zero and infinity, follow codec NaN rules |
| string, bytes, symbol | corresponding variants | Distinct tags, no normalization |
| list, tuple | `.list` / `List` | Tuple adds exact arity, integer-run variants are a representation optimization |
| struct, string-keyed map | `.struct` / `Struct` | Optional presence differs from explicit undefined, preserve declared extensions |
| arbitrary-key map | neither public value API | Unsupported target, do not stringify keys |
| tagged, positional record | `.tagged` / `Tagged` | Existing `user-record` envelope, preserve tag and all positional fields |
| set | `.set` / `Set` | Existing Syrup set support, canonical ordering belongs to codec |
| keyword | `.keyword` / `Keyword` | Existing profile form, distinct from symbol |
| float32, arbitrary-label record | neither | Unsupported target, no widening or label conversion |
| target, interface | `.capability` / `Reference(Ref)` | Host-owned references, interface expectation adds no authority |
| promise<T> | runtime pending reference / outbound `PromiseArgument` | Incoming reference can remain opaque, no forced await or promise-kind probe |
| error | `.error` / `Error(String)` | Current message-bearing error form, arbitrary breaks stay on the outcome path |
| value | complete public value union | Recurse through all supported forms, including references, not host-native objects |
| union, recursive type | generated checked projection | No new wire tag, require unambiguous discrimination and bounded traversal |

The TypeScript probe maps this profile's void value to JavaScript `null`, as
the binding does. Its typed observation returns `undefined` locally. This
does not add support for the contract's separate `null` value.

The target mapping is deliberately not a claim that either raw binding already
implements the entire draft model. Core corpus qualification must test both
profiles separately, including explicit unsupported-target diagnostics.

## Independent acceptance cases

These cases constrain the compiler tests added in milestone 2, the current
fixture check does not claim to execute them.

| Boundary | Accepted / refused cases |
| --- | --- |
| UTF-8 bounds | 1 and 4,096 text bytes accepted, empty and 4,097 refused, multibyte strings counted by bytes |
| Parameters | Exact arity, missing required or excess arguments refused, optional cursor omitted or 56 bytes, never 55/57 or void |
| Integers | i64 endpoints and big integers round-trip, Index -1 refused, Sequence 0 refused |
| Copied data | Missing/null/undefined distinct, closed-record extra field refused, extension fields preserved, depth budget enforced |
| Reply projection | Wrong creation result, observation tag/arity, nonboolean reset/changed, malformed cursor, or missing canceller refused |
| Receipts | Identical replay applies once, different arguments at same sequence conflict, reply loss does not imply rollback |
| Authority | Read-only/revoked access refused, stale membership and full destinations remain runtime decisions |
| Pending references | Drop or observe original before prepared submit/replay, cross-Host refused, release after completion, failed typed observer cannot poison raw observer |
| Names | `then`, `constructor`, `__proto__`, `type`, `a-b`, `a_b`, empty name, quotes, backslash, newline, and non-ASCII wire names preserved |
| Paths and collisions | `../escape`, absolute paths, case-fold collisions, reserved filenames: no output escape or overwrite, deterministic escaping, no wire-name rewriting |
| Compiler input | Unsupported version/profile, duplicate keys, dangling refs, alias cycle, ambiguous union, overflow, truncated data, graph/output exhaustion |

The existing raw read handlers sometimes ignore excess arguments. Generated
strict arity is a new adapter guarantee, not a statement about those handlers.
The generated adapter must preserve extension dispatch and must not reject an
unrecognized method before the application's existing fallback gets it.
