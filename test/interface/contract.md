---
type: static
description: The interface description's Syrup encoding, target mappings, compiler limits, and acceptance cases.
sources:
  - resource: /test/interface/contracts.syrup
  - resource: /test/interface/messages.syrup
  - resource: /tools/interface/
---

# Interface description and fixture contract

The [Syrup description](contracts.syrup) is the independent expected Tasks and
callback corpus. [Authored modules](authoring/contracts/contracts.interface)
supply generation input. This reference specifies encoding, mappings and acceptance cases.

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
A text frontend must produce the same graph rather than add a second
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

Method keys are exact wire names as strings. False denotes a direct signature
for the whole wire argument list, with no selector prepended by the caller.
An empty string denotes the named shorthand that prepends an empty symbol.
There is no extra wire tag distinguishing a direct call whose first argument
is a symbol from a named call carrying the same list.

The current language allows one direct signature or named methods per
interface. The shared model enforces that scope for every frontend. A direct
receiver using a binding's `verb` and `args` must restore a peeled leading
symbol before checking the whole list. The generated Zig receiver proof covers
a fixed two-value call with an undefined result on both profiles, including
`[symbol, integer]`, refusal before handler entry, and a named receiver control.
Other direct signatures, rest arguments, and receiver targets remain outside
that projection.

Conventions are
`call`, `tell`, and `loam.receipt`. A tell result must be `undefined`, denoting
no result channel. A receipt method must be named.

Required parameters precede optional parameters. Absence is a shorter argument list, never null or void.
A final `rest` parameter record holds a source name and element type. It cannot
follow optional parameters. It accepts the remaining arguments without wrapping
them in a list.

Bounds are `min`, `max` for integers, `min_bytes`, `max_bytes` for strings and
bytes, and `max_items` for containers. A bounded container wraps its type expression
instead of a primitive symbol. String limits count UTF-8 bytes. Restrictions
on aliases intersect: a wider outer bound cannot relax an inner bound, and an
empty intersection is invalid. Reject unknown
records, profiles, fields, conventions, unresolved names, contradictory bounds,
ambiguous unions, and unproductive alias cycles. Recursive copied structures
may contain references to themselves, but runtime copied values must be acyclic.

Before emission, the compiler limits input to
<!-- value ../../tools/interface/description.zig max_input_bytes bytes -->1 MiB<!-- /value -->,
<!-- value ../../tools/interface/model.zig max_definitions -->4,096<!-- /value --> definitions,
<!-- value ../../tools/interface/description.zig max_nodes -->65,536<!-- /value --> graph nodes,
<!-- value ../../tools/interface/description.zig max_depth -->64<!-- /value --> nested type constructors, and
<!-- value ../../tools/interface/model.zig max_parameters -->256<!-- /value --> parameters per method.
These are compiler resource ceilings, not OCapN limits.
Graph validation needs a visited set and explicit work budget. Canonical input
is still untrusted. Reject duplicate dictionary keys while parsing, because decoding
into an overwriting map is insufficient. The upstream fixture reader is used
only on repository-owned inputs and is not the proposed production parser.

`glowcap.values: 1` names the local target mapping below, and `loam.receipt: 1`
names the existing preparation convention. They are build requirements, not
wire negotiation or community profile names. Every description declares
`glowcap.values: 1`. The receipt profile is required when any method in the
bundle uses `loam.receipt`, including a method not selected for emission.
Descriptions without receipt methods may omit it. A supported declared profile
may remain unused, but unknown profiles and unsupported versions are refused.

Both authoring adapters omit the receipt profile when no method uses it.
The existing comparison corpus retains both supported profile entries.
The ordinary Rust projection does not require the binding's `loam` feature.
These build requirements do not change the session profiles `1.0` and
`glowcap-next`. A description cannot change a live session.

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

Generated Rust handles select the binding's owned-outcome policy before
observation. Returned capabilities, including opaque nested values, release
their occurrences on final drop even when the Host's automatic release is off.
Refused and partially decoded replies receive the same cleanup. Independent
raw observations keep their own release policy and settlement.

Preparation copies and validates data and retains references **before** it
suspends for sequence acquisition. Submission retains the exact target,
sequence, and snapshot. Replay never acquires a fresh sequence automatically.
Uncertain commit, conflict, expiry, local validation, wrong fulfillment, remote
break, and transport failure remain distinguishable. Unknown break values
remain observable, and declared break cases must not close the error universe.

Ordinary Rust calls use unit for undefined and `Option` for optional arguments.
They return a local validation result around the pending handle when an optional
suffix could contain a hole. TypeScript counts supplied arguments, so an omitted
argument differs from explicitly passed `undefined`. A present source-undefined parameter is encoded
as the binding's `null` representation for void.

An optional `Argument` parameter
widens the TypeScript signature with `undefined`, so a supplied value is narrowed
before local or far dispatch. Required `Argument` parameters retain the raw
passability contract. Contract null is still unsupported.

The scalar fixture qualifies booleans, bytes, symbols, float64, and fulfilled
error values in Rust and TypeScript. Calls and tells cover required and optional
inputs on both profiles. Bytes preserve declared byte limits through local input
checks and fulfillment checks. Rust uses `bool`, `Vec<u8>`, `String`, and `f64`,
with separate wire tags for symbols and error strings.

TypeScript uses `boolean`,
`Uint8Array`, `Sym`, `number`, and `Error`. Strings cannot substitute for symbols
or error values, other typed-array views cannot substitute for bytes, and integer
values cannot substitute for float64.

Float edge cases follow the raw bindings,
including signed zero, subnormals, infinities, and NaN. Error fulfillment and
remote break remain separate outcomes. Null remains unsupported. Compound
replies have the separate mappings below.

Rust receipt methods use the same scalar and compound reply projections as
ordinary calls. Preparation validates scalar inputs, copies borrowed text and
retains the target and capability or pending arguments for the receiving Host
before asking for a sequence. Foreign and released references refuse locally.
Opaque-value and compound receipt inputs remain unsupported.

The prepared request owns one argument vector after acquisition and reuses it
for every submission. It never refreshes a sequence or resends automatically.
Both wire profiles cover pending and settled inputs with data, capability, and
broken outcomes. Replay checks the same envelope and authority, respecting
runtime shortening and terminal promise-wrapper behavior.

Tasks' Rust client uses generated add, move, observe, poll, and cancel calls.
Registration requires exactly two capabilities, without certifying their remote
interfaces. Move checks the declared count result and cancel requires a Boolean,
including false. If the first poll fails after observe commits, the application
attempts cancellation once and preserves the primary failure.

An identical replayed promise is observed once. The current Host observation
path exposes the one settling listener glowcap-next permits across the wire.
It does not multicast that listener to multiple local observers.

The callback fixture opens a Reader through Factory, calls Sink.push with it,
and passes a still-pending Reader to Factory.accept. Reader has a wire method
named `then`. Generated Rust and TypeScript callers check positional,
empty-symbol, and named invocation on both profiles. The raw Rust notification
behavior verifies that a tell has no result channel. Qualification must hold the factory reply
pending while admitting the dependent calls. A pre-resolved answer is not proof.

The Rust matrix drops unobserved handles and polled observations while retaining
the argument. TypeScript closes with original, repeated, and pipelined
observations active. Both retain remote break messages as runtime failures and
check that typed observation preserves the independent raw outcome. Both
profiles are asserted at the shared fixture boundary.

The handoff fixture declares Introducer.get-greeter returning Direct.
A generated Rust client receives Bob's greeter from Alice and calls it
positionally. Independent message fixtures define the request and expected
reply. The other test uses Goblins to create Tasks through the generated Zig
argument checker. Both tests check Syrup/V1.0 negotiation. The runtime still
handles handoff, and Loam creates Tasks and builds their capability replies.

The runtime owns promise, settlement, and listener behavior. The generator
must adapt to its public ownership contract. Qualification covers independently
retained pending arguments, listener cancellation, repeated observation, and
references surviving answer release. ADR-0070 supplies stored
resolution retention. It does not by itself prove a binding exposes every
operation preparation needs. No generator-owned vow registry is permitted.

Rust receipt preparation owns the sequence-query outcome before observing it,
including when raw Session calls use manual release. A malformed sequence reply
is discarded without leaking its capabilities. A Syrup wire observation checks
that this release happens before session close with either raw release policy.

## Rust compound replies

Lists decode to owned `Vec<T>` and tuples to positional Rust tuples. Tagged
records check their exact tag and field count before decoding each position.
A selected explicit type export makes a positional tuple struct, such as
`LoamObservation(Vec<u8>, Argument, bool, bool, Vec<String>)`.
The source form `record<"tag", T...>` preserves those positional fields.
`tagged<"tag", T>` preserves one payload, including a nested tuple.
String-keyed data uses the reserved `struct` declaration, which remains unsupported.

`Receiver.poll` checks the 56-byte cursor, both booleans, and every notice symbol.
Unknown and duplicate notices preserve their order. Description remains opaque
`Argument`, including retained capabilities and application-specific records.
The decoder does not apply Loam's semantic observation-description reader.
Watcher keeps its previous cursor after any failure and moves in a valid reply's
cursor. Its optional input cursor still requires one owned snapshot.

If initial polling fails after observe commits, `Board.watch` attempts one
`cancel` before returning the poll failure. A failed cancellation adds diagnostic
context without replacing the primary error. A live Watcher remains available
after later poll failures and is cancelled by its explicit `stop` call.

Rust emission also limits expanded inline structure to
<!-- value ../../tools/interface/compound_graph.zig max_inline_structure -->256<!-- /value -->
units per emitted node. A tuple or record counts its container plus inline
fields, and each scalar or list slot counts once. List element types are checked
independently. Excess returns compiler `ResourceLimit` before output, without
boxing or changing the representation. This is a compiler layout guard, not a
schema cardinality bound or exact Rust byte estimate.

Declared list bounds are separate from the generated decoder's work limit.
Normalization bounds the finite type graph before emission, so generated
decoders need no runtime depth counter. A schema violation returns `InvalidReply`, while exhausted decoder work
returns `ResourceLimit`. Compound inputs remain explicitly unsupported.
Productive copied recursion validates as a description
but is refused for this projection. Alias-only cycles remain invalid.

## TypeScript compound replies

Lists and tuples expose passable object views with readonly indexing, length,
and iteration. Fixed tuples retain precise numeric positions and literal length.
The pinned TypeScript check also qualifies positional destructuring. Array-only
methods require an explicit caller conversion, such as `Array.from`.

Wire lists arrive as `Argument[]`. Local sends can preserve `BigInt64Array`,
which represents the same list of integers. Both representations keep their
original objects. Tagged positional records retain their actual array payload,
exact tag, and field count. Generated aliases share nested types and helpers.

`Receiver.poll` returns the existing record with its typed positional payload.
It checks the cursor's byte length, both booleans, and each notice's `Sym`
category. Unknown and duplicate notices retain their order.

Validation returns the original array or record. Payloads and capability
wrappers keep their identity and existing runtime ownership. An opaque `value`
field needs no projection, including nested records and capabilities. A source
`undefined` field remains the binding's raw `null` value inside a compound,
while a top-level undefined reply exposes `void`. Source `null` remains refused.

Generated handles select Host reply tracking before observation. Each projected
capability occurrence is registered with the Host's finalizer owner, including
opaque nested values and rejected replies. Saved raw aliases keep the same live
wrappers. Borrowed local results retain their original release policy, while local
forwarding carries the selection to a peer send. Independent raw Session calls
keep their opt-in policy.

Readonly indexing restricts the generated view, without freezing the object or
adding a membrane. Views remain passable to raw calls and opaque parameters
without copying or casting.

Each observation allocates one temporary work-counter object shared by recursive
helpers. Decoder work is limited to
<!-- value ../../tools/interface/compound_graph.zig max_reply_work -->65,536<!-- /value -->
schema visits. Opaque fields need no element read or work charge, and a
`list<value>` checks only its container and declared length bound. Its length
adds no decoder work limit because its elements require no traversal.

Packed runs also establish integer categories and the full i64 interval. Only
narrower integer bounds need a per-element scan. Empty packed runs satisfy any
list element schema, and fixed tuples still check exact arity. Budgets charge
actual checks across nested representations, with no speculative work score.

Exhaustion throws exported `ResourceLimit`. Category, tag, arity, and schema-bound
violations throw `TypeError`. Either refusal leaves independent raw observers
and the runtime's original settlement intact. Remote breaks retain their runtime
failure object.

Both targets use the same bounded graph traversal and inline-structure admission.
Compound inputs and productive recursive projections remain unsupported.
Rust `list<value>` returns its existing `Vec<Argument>` directly. Other owned
list element layouts need a result vector and per-element projection.

## Tasks Rust read projection

Five ordinary calls in the real Rust application use checked generation:
Board.list, TaskList.name, TaskList.count, TaskList.task, and Task.text.
They retain the declared Name and Text byte bounds, TaskCount range, and Index
range from zero through signed-64-bit maximum. List and task membership still
belongs to the server. Zig read handlers use generated argument and scalar reply
checks. Storage conversion stays with the application.

Bounded arguments return a local validation result around `Pending<T>`.
Invalid input creates no call or error promise. Valid calls send immediately.
Zero-argument reads return `Pending<T>` directly. Typed observation reports
`InvalidReply` for wrong reply types or bounds and preserves runtime failures
and independent raw observation. Bounded text decoders move the binding's
owned String after checking its UTF-8 byte length.

Description bound literals use the reader's signed-64-bit metadata
representation. This limits schema literals, not OCapN Integer values.
The Rust typed integer projection requires both declared endpoints and
supports their finite signed-64-bit interval exactly. Bare and partially bounded
integers receive `UnsupportedTarget`. Raw bindings still support bignums, as
the value table below states.

## TypeScript scalar bounds

Integer calls use exact JavaScript `bigint`, including values outside i64.
Number values cannot substitute for integers. Bare and empty bounds add no
range restriction. Partial and full bounds compare bigint literals directly,
without narrowing or coercion. Schema endpoint metadata remains signed-64-bit.
Normalized alias restrictions retain their intersection in both directions and
in nested compound replies.

Bounded text counts the UTF-8 bytes that the binding's `TextEncoder` emits.
Paired UTF-16 surrogates count four bytes. Unpaired surrogates count three bytes,
matching U+FFFD replacement in the existing binding. The validator passes the
original string unchanged. It neither encodes a byte snapshot nor changes the
binding's encoding behavior.

The scan admits the counter's exact numeric range once using the maximum of
three bytes per UTF-16 unit. It refuses at the first byte exceeding a maximum,
and a minimum alone stops once satisfied. Required and optional calls and tells
apply the same guards. Schema failures throw `TypeError` before sending, while
generic passability failures keep the binding's failure type and result channel.
Generated checks establish declared shape, not authorization or Host admission.
The [validation ownership decision](../../docs/decisions/adr/ADR-0069-proposed-interface-language.md)
owns that distinction.

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
| value | complete public value union | Recurse through all supported forms, including references, not arbitrary language objects |
| union, recursive type | generated checked projection | No new wire tag, require unambiguous discrimination and bounded traversal |

The TypeScript probe maps this profile's void value to JavaScript `null`, as
the binding does. Its typed observation returns `undefined` locally. This
does not add support for the contract's separate `null` value.

The target mapping is deliberately not a claim that either raw binding already
implements the entire draft model. Core corpus qualification must test both
profiles separately, including explicit unsupported-target diagnostics.

## Independent acceptance cases

These cases constrain the compiler and proof tests. The fixture check does
not execute them.

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
