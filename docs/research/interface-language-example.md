# Interface language design and complete example

The candidate language describes messages once so generators can remove manual
encoding, decoding, and dispatch. It is not implemented or an OCapN proposal.
[ADR-0069](../decisions/adr/ADR-0069-proposed-interface-language.md) owns the
architecture and alternatives. The rules below define the design to implement
and test, rather than leaving the difficult semantics to each generator.

The language has declarations and type expressions, with no executable code,
implicit conversions, default values, or user-defined validation functions.
A method reads like a method. Type notation names wire distinctions only when
an author needs them. Runtime operations stay in the runtime API.

The example uses the proposed core language. It has concrete named types and
interfaces. User-defined type parameters and interface inheritance are outside
this version. Built-in constructors such as `list<T>` and `promise<T>` remain
available without a general specialization or inheritance mechanism.

## The complete declaration example

The syntax describes copied values, live references, and messages. Names of
interfaces denote references expected to support those methods. `promise<T>`
denotes a passable reference expected to fulfill to T. These are expectations,
not a requirement to discover an object's methods or a promise's current state.
Every ordinary call itself returns a promise for its declared result.

```text
module example.workspace
import "profiles/durable.interface" as durable
requires durable.locators

// Application bounds, not OCapN-wide limits.
type Name = string(max_bytes: 128)
type Chunk = bytes(max_bytes: 1_048_576)
type Offset = integer(min: 0, max: 18_446_744_073_709_551_615)

// Every atom in the draft model.
record Atoms {
  absent: undefined
  nothing: null
  enabled: bool
  exact: integer
  measured: float64
  text: string
  binary: bytes
  token: symbol
}

// Fixed and variable sequences, structures, and tagged values.
type Position = tuple<float64, float64>
type Labels = list<Name>(max_items: 64)
type Properties = map<string, value>
type Decimal = tagged<"example/decimal", tuple<integer, integer>>
type Mode = symbol("snapshot") | symbol("live")

record Metadata {
  name: Name
  length: Offset
  position: Position
  labels: Labels
  properties: Properties
  price: Decimal

  // Missing key, explicit null, explicit undefined, and a string differ.
  description?: string | null | undefined
}

// Explicitly preserve fields this version does not recognize.
record ExtensionData {
  name: Name
  ...extra: value
}

// Recursive copied data. No cyclic copied object graph is implied.
record Tree {
  name: Name
  children: list<Tree>
}

// Concrete tags and payloads, not implicit ordinal discriminants.
type MetadataStep = tagged<"example/item", Metadata>
             | tagged<"example/end", undefined>

type Event = tagged<"example/changed", Metadata>
           | tagged<"example/removed", Name>

type OpenFailure = tagged<"example/not-found", Name>
                 | tagged<"example/denied", undefined>

// Arbitrary targets and promises can occur inside copied containers.
record Mixed {
  object: target
  document: Reader
  pending_document: promise<Reader>
  pending_metadata: promise<Metadata>
  references: list<Reader | promise<Reader>>
  opaque: value
  diagnostic: error
}

// Named method dispatch. A quoted name is an exact wire symbol.
interface Reader {
  read(offset: Offset, count: Offset) -> Chunk
  metadata() -> Metadata
  "read-all"() -> Chunk
}

// Editing access and its separately obtained read facet.
interface Document {
  write(offset: Offset, content: Chunk) -> Offset
  reader() -> Reader
}

// Direct invocation, without a symbol selecting a method.
interface Greeter {
  (name: Name) -> string
}

// The untyped message path also remains expressible.
interface AnyReceiver {
  (...arguments: value) -> value
}

// One-way delivery: no result promise or remote failure acknowledgment.
interface Observer {
  tell changed(event: Event)
}

// A one-way direct invocation also needs no method selector.
interface Notify {
  tell (message: value)
}

// A callback returning a result can express application flow control.
interface ChunkSink {
  push(item: Chunk) -> undefined
  finish() -> undefined
}

// Pull streaming is an application object protocol.
interface MetadataCursor {
  next() -> MetadataStep
  close() -> undefined
}

// Separate authority to stop receiving notifications.
interface Subscription {
  cancel() -> undefined
}

// Separate authority to revoke an application-managed forwarder.
interface Revoker {
  revoke() -> undefined
}

record SharedDocument {
  access: Reader
  control: Revoker
}

// These signatures describe the CapTP resolver object's message forms.
interface MetadataResolver {
  tell fulfill(value: Metadata | promise<Metadata>)
  tell "break"(reason: value)
}

interface Workspace {
  // Recognized application failures. Unknown breaks remain possible.
  open(name: Name) -> Reader throws OpenFailure
  edit(name: Name) -> Document throws OpenFailure

  // Returning multiple results means returning one copied container.
  split(document: Reader) -> tuple<Reader, Reader>

  // Passing references, unresolved promises, and callback objects.
  attach(document: Reader | promise<Reader>) -> undefined
  inspect(metadata: promise<Metadata>) -> undefined
  watch(observer: Observer, mode: Mode) -> Subscription
  copy_to(document: Reader, sink: ChunkSink) -> Offset
  children(prefix?: Name) -> MetadataCursor

  // The holder explicitly grants settlement authority.
  compute(input: value, completion: MetadataResolver) -> undefined

  // Application patterns, not extra CapTP operations.
  share(document: Document) -> SharedDocument
  remember(document: Reader) -> durable.ReaderLocator
  restore(saved: durable.ReaderLocator) -> Reader

  // Exercise all modeled data and preserve unfamiliar values.
  atoms(value: Atoms) -> Atoms
  tree(value: Tree) -> Tree
  mixed(value: Mixed) -> Mixed
  echo(value: value) -> value
}
```

## Source and names

A module contains aliases, records, and interfaces. Imports name local files
explicitly and bind a module alias, as in `import "loam.interface" as loam`.
Import resolution uses a supplied root and pinned inputs, never ambient network
access. Modules can reference each other's types within a bounded resolved
graph. Missing files, duplicate declarations, and conflicting imports are errors.
Source locations remain attached through resolution.

Identifiers use ASCII letters, digits, and underscores, starting with a letter
or underscore. Quoted method and field names express other exact Unicode names.
Quoted strings use JSON escapes and reject unpaired surrogates. Source is UTF-8,
`//` introduces a line comment, and whitespace does not change type meaning.
Bounds are integer literals, with optional underscores, rather than expressions.
The public formatter preserves comments and has one stable output for each input.

An unquoted method identifier is its exact wire symbol, with no case conversion.
A quoted name such as `"read-all"` also selects a symbol, not a string.
Parameter labels never enter the argument list. A record field names an exact
string key. Renaming either wire name changes the contract.

Generated identifiers use deterministic, collision-free escaping for each
host language, including reserved hooks such as JavaScript's `then`.
Wire names and literals use the target language's string escaping. Render
diagnostics and comments safely, including newlines and comment delimiters.
Names cannot inject source code or select output paths outside the output root.

## Values and bounds

`record` is a copied structure with string keys. `tuple` is a fixed-shape list,
`list` a variable-length list, and `map<string, T>` a string-keyed structure.
`tagged<"name", T>` has an exact string tag and one payload. A tuple payload
remains one payload, not a variadic Syrup record.
`symbol("name")` is a literal symbol, distinct from a string.

Bounds have explicit units: inclusive `min` and `max` for integers,
`min_bytes` and `max_bytes` for bytes or UTF-8 text, and `min_items` and
`max_items` for containers. Contradictory or inapplicable bounds are errors.
Aliases intersect restrictions rather than replacing them. Check lengths
before allocating outputs, with checked arithmetic for sizes and capacities.
Unbounded schema types still run under the caller's finite resource budgets.

`integer` preserves arbitrary precision. A generator may use a machine integer
only when the declared range fits exactly. TypeScript uses `bigint` for the
unrestricted type. `float64` preserves negative zero and infinities and follows
the selected profile's NaN rules. Strings and symbols are never normalized or
coerced into each other. Neither JSON nor a lossy host number is an intermediate
representation for values or descriptions.

`value` admits every passable value of the selected profile, including nested
references and promises. It preserves unfamiliar values rather than silently
projecting them onto known fields. It does not admit arbitrary host pointers,
closures, or cyclic copied containers. `error` names the draft category without
inventing a portable stack trace or universal exception envelope.

The source distinguishes null, undefined, missing, and empty. A target lacking
one of those encodings refuses the relevant contract or value explicitly.
Representing the draft vocabulary does not claim every runtime implements it.
The [conformance manifest](../ocapn-conformance.md) owns runtime status.

## Optionality, unions, and recursion

`field?: T` means that the key may be absent. Present null or undefined must
be admitted explicitly by T. Records are closed by default, so unknown keys
fail. An explicit final `...extra: value` field captures unknown keys and their
values, including reference ownership, without adding an `extra` key on the
wire. Re-encoding preserves them. Duplicate keys are refused.

Optional positional arguments form a trailing suffix, as in
`children(prefix?: Name)`. Omission shortens the argument list. It does not
insert undefined. A final `...arguments: T` admits a variable tail.
Optional parameters and a variable tail cannot coexist in one signature.

Fixed signatures reject extra arguments. There is no implicit overloading,
numeric coercion, default injection, or discarded tail.

A union adds no wire wrapper. Copied-value alternatives must be distinguishable
by value category, exact literal, or explicit tag. Other overlapping shapes
require tags rather than a general structural-disjointness solver.
Uncertainty is a compile error, not ordered trial decoding.
`Reader | Writer` cannot discriminate by claimed interface, and
`promise<string> | promise<integer>` cannot discriminate by awaiting it.
Use explicit tags when the distinction matters.

The object-or-promise form with the same expected interface is coalesced into
one reference view, as described below. It has no runtime union discriminator.

Recursion must pass through a container, reference, or promise constructor.
Alias-only cycles are rejected. Named references form a finite type graph
without expanding the whole definition at every use. Compilation, validation,
and decoding have explicit work and depth limits. No validator recursively
walks the remote object graph.

## Calls, capabilities, and promises

An interface describes named dispatch or one direct-invocation signature.
Mixing both is refused rather than guessing which dispatch a message intended.

The example's `reader()` must return an actual restricted facet to withhold
write authority. Changing only the static type does not restrict access.

`f(...) -> T` declares the eventual fulfillment value of a call. The generated
method initiates a send immediately and returns a typed handle over the
existing runtime promise. It does not become a lazy Rust async function or a
JavaScript async wrapper that loses the runtime's passable handle.
`-> promise<T>` is rejected as a redundant promise layer: settlement adopts
promises. To return a promise as data, place it inside a copied container.

Interface names describe callable reference expectations. `target` leaves the
interface unspecified. `promise<T>` describes expected fulfillment, including
promises inside containers. Admission and shortening follow the runtime profile.
An ordinary host-language future is not automatically passable.

Received promises and objects can share an opaque binding representation.
The generator must not infer their kind from a handle or query the peer to
choose a union arm. `Reader | promise<Reader>` uses one reference view with the
same expected Reader operations, without exposing a false arrival-state tag.
Different reference expectations need explicit application tags when the caller
must distinguish them. `promise<string | integer>` checks its data union when
observed rather than trying to classify a pending promise.

Validation has three different responsibilities:

| Value received | What generated code can establish |
| --- | --- |
| Copied data | Shape, bounds, tags, and supported value representation |
| Capability | Host admission, with an expected interface that is not remotely certified |
| Promise | Host admission of a passable reference now, with fulfillment validation when observed |

No schema check calls an object to ask whether it implements an interface.
Typed references do not prove behavior. A received promise is not awaited while
decoding its enclosing call. Observing its fulfillment validates T, while
forwarding or pipelining it uses the original handle and owner.
A typed view must not install a proxy that changes identity or authority.

Malformed copied input is rejected before the typed handler runs. A promise
that later fulfills incorrectly can already have reached that handler, so its
typed observation reports the failure. These are different guarantees.

A dependent call may execute before local validation of its source result.
Pipelining therefore cannot promise that every preceding reply was checked
first. An application needing that ordering must await and validate explicitly.
Malformed results fail their typed observation without rewriting shared Host
settlement or canceling unrelated raw observers.

`tell f(...)` requests no answer. Local validation and admission may still fail,
but there is no remote success acknowledgment. No generator adds automatic
retry, timeout, cancellation message, or promise listener merely to typecheck.
Explicit observation uses the runtime's existing listener machinery.

`throws E` describes recognized break reasons, with an open remainder.
Generated callers preserve unknown reasons and distinguish local argument
failure, invalid reply, remote break, and runtime failure. A failed response
is not proof that the operation had no effect. Server diagnostics remain local
unless the application deliberately exposes them.

## Profiles and application protocols

Required profiles identify versioned value mappings and application conventions.
The compilation target fixes supported profiles before generation. An unknown
required profile or semantic annotation fails rather than being ignored.
The canonical description records resolved profile identifiers and versions.
Descriptions do not negotiate or change a live session's wire profile.

Wire mappings and application conventions are separate entries in the checked
model. Loam annotations select built-in lowering rules, not executable plugins.
A new convention requires a compiler change and fixtures. Ordinary application
protocols use imported declarations without adding compiler behavior.

`@loam.receipt` selects Loam's existing mutation convention. Its definition
owns the outer `mutate` symbol, inner operation string, sequence exchange, and
retained request API. It supplies no authorization, participant validation,
transaction implementation, or automatic retry policy.

Snapshot copied inputs, validate that snapshot, and retain references before
suspending to acquire a sequence. Retain the request's exact target, identity,
and inputs across submission and replay. Later caller edits cannot change them.
Receipt expiry and conflicts remain observable outcomes.

Library declarations supply observers, cursors, resolvers, and subscription
protocols. `durable.ReaderLocator` is a concrete imported locator declaration,
not another intrinsic value category or an instruction to redeem during decode.
The example's durable library is illustrative. Its actual definition and profile
version must be supplied with the compiler's checked fixtures.
Revocation, persistence, cancellation, and scheduling stay with their owners.
Library imports avoid repeating these contracts in every application file.

The initial language excludes user macros, executable annotations, expression
languages, automatic effect inference, and remote type casts. Add a construct
only when an actual contract cannot be expressed clearly with the existing
forms. Covering OCapN does not require turning each protocol operation into a
language feature.

## Canonical descriptions

Syrup stores the resolved contract as a versioned, bounded graph of named
definitions and tagged type expressions. Method tables use exact wire names
as keys, while parameter lists preserve order. Referenced definitions and
profile versions are included, so imports cannot silently change meaning.
Source locations remain compiler diagnostics rather than machine-specific
paths inside the description.

The compiler accepts these descriptions as build inputs through the same
validation as text. It checks format versions, names, references, types, bounds,
profiles, and resource limits before emission. Canonical bytes confer no trust.
Each contract has one authored source. A description generated from text is
an output to regenerate, not a second file to maintain by hand.

Canonical encoding makes the same description deterministic. Reordering method
declarations must leave its bytes unchanged. A digest identifies that content,
not every semantically equivalent spelling of a recursive type graph.
Generation records the compiler version, target mapping, and transitive inputs.
A check regenerates and compares outputs rather than trusting a digest comment
in a possibly edited generated file.

## What calling it looks like

This is language-neutral runtime pseudocode, not another part of the IDL.
`pipeline()` exposes the expected interface on the pending answer without
waiting. `as_argument()` requires an owning passable view of that same answer,
including after the original call handle is dropped or observed. This is a
proposed API contract, not a claim that copying a binding's argument handle
already retains its vow. Qualify that ownership at the binding or Host first.
Export, listen, settlement, and release use existing runtime facilities.

```text
workspace = redeem<Workspace>(saved_workspace)

// Pipelining: send read before the open reply arrives.
document = workspace.open("notes")
content = document.pipeline().read(0, 4096)

// Passing the pending answer, without awaiting it first.
workspace.attach(document.as_argument())

// Export an application object for calls in the reverse direction.
observer = export<Observer>(local_observer)
subscription = workspace.watch(observer, symbol("live"))

// Create a passable promise and its distinct settlement authority.
(pending, resolver) = make_promise<Metadata>()
workspace.inspect(pending)
resolver.fulfill(local_metadata)
// Alternatively, break it, or adopt another promise by fulfilling with it.

// Hold authority to settle someone else's future result.
(output, completion) = make_promise<Metadata>()
workspace.compute(input, completion)
listen(output, fulfilled_handler, broken_handler)

// Alice holds a Reader hosted by Carol and sends it to Bob.
bob_workspace.attach(carol_reader)
// Runtime performs any required introduction and redemption with Carol.
round_trip = await workspace.echo(carol_reader)
assert same_target(round_trip, carol_reader)

// Control authority is held separately from ordinary access.
editable = await workspace.edit("notes")
shared = await workspace.share(editable)
recipient.attach(shared.access)
shared.control.revoke()

subscription.cancel()
release(subscription)
release(observer)
release(document)
```

A promise may fulfill to data, a target, or another promise, or break with a
reason. Sending messages to a promise only reaches a callable target if its
eventual fulfillment is one. Failure propagates to dependent results.
Listening does not make a promise an ordinary target with stable identity.
The runtime enforces settlement, ordering, and forwarding behavior.
Object references can form cycles even though copied containers cannot.

The pseudocode abbreviates local result handling. It does not await every
preceding call, serialize concurrent calls, guarantee completion, or imply
that canceling a local wait undoes a remote effect. `Subscription.cancel`
is an explicit application operation. Release manages a local reference,
not the existence of the remote object.

## Coverage and profile boundaries

The [OCapN model](https://github.com/ocapn/ocapn/blob/main/draft-specifications/Model.md)
records both agreed types and open questions. The
[CapTP draft](https://github.com/ocapn/ocapn/blob/main/draft-specifications/CapTP%20Specification.md)
owns message and reference operations. The
[Syrup draft](https://github.com/ocapn/syrup/blob/master/draft-specification.md)
also describes values outside the common OCapN model.
These are separate authorities, not one frozen profile.

| Facility | Where this example puts it |
| --- | --- |
| Undefined, null, bool, integer, float64, string, bytes, symbol | Atom declarations |
| Lists, string-keyed structures, tagged values | Lists, records, maps, and tags |
| Target references and promises within values | Interface types, `target`, `promise<T>`, Mixed |
| Errors and broken promises | `error`, open `throws`, resolver break, broken handler |
| Method selection and arbitrary invocation | Named, quoted, unnamed, and variadic signatures |
| Calls and send-only messages | Ordinary signatures and `tell` |
| Pipelining, promise arguments, listening, promise adoption | Runtime example and explicit promise types |
| Reverse calls and exported objects | Observer, ChunkSink, and local export |
| Streaming, flow control, unsubscribe | Application cursor, sink, and Subscription protocols |
| Delegation, attenuation, revocation | Reference arguments, actual facets, separate Revoker |
| Third-party handoff and target identity | Runtime introduction, redemption, and session reference tracking |
| Durable references and bootstrap fetch | `durable.ReaderLocator` and explicit redemption |
| Session opening and closing, netlayers, encryption | Runtime and transport configuration |
| Import/export positions, answer positions, distributed GC | Session-owned reference bookkeeping |
| Signature envelopes, gift descriptors, handoff counters | Session-owned handoff validation |
| Interface discovery and fingerprints | Optional tooling above these declarations |
| Timeouts, quotas, scheduling, persistence transactions | Application or hosting policy, with explicit owners |

Full Syrup additionally permits binary32 floats, sets, arbitrary-key
dictionaries, and records with arbitrary labels and positional fields.
A separately required Syrup profile could expose them as follows:

```text
requires syrup

type Samples = list<syrup.float32>
type Members = syrup.set<integer>
type Index = syrup.dict<integer, string>
type Legacy = syrup.record<symbol("legacy/point"), float64, float64>
```

These names are profile syntax proposals. They do not establish portable
OCapN support. A consumer that does not implement a required profile refuses
the description rather than translating its values into different types.
The model's tagged and error forms also need their selected wire mapping.
A missing Null encoding must not disappear behind an alias for undefined.

## Implementation qualification

These are candidate semantics, not a shipped grammar or a promise of community
adoption. The compiler must publish an exact grammar, versioned description
schema, profile mappings, and independent positive and negative fixtures.
Errors must identify the declaration and argument or field that failed.
The full application proof must verify generated behavior and ownership,
including the promise distinctions above. A parser/printer round trip cannot
establish those properties.
