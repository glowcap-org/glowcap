# The interface model

Status: active plan, waiting for maintainer review before work starts.
Phase one of [interface definitions](interface-definitions.md). Delete this
plan when its steps land.

## What this is for

Before anyone writes a text language, a generator, or a wire convention, the
thing they all produce and consume has to exist: a description of an
interface as a Syrup value, and one Zig module that knows every rule about
such values. This phase builds that module and proves it against the two
interfaces the project already has, Tasks and Rooms. When it lands, a
description can be read, written, fingerprinted, compared with another, and
used to check a call's arguments and reply. Nothing is generated and nothing
is on the wire.

## Where things stand

The Rooms grammar table carries eight value types, including a nonempty
string, a pattern type, a reference, and a list with a sibling row table. It
has no bounded integers, no named record fields, no error lists, no effect
marks, and no notion of one interface referring to another. The Tasks server
splits its verbs into readers and writers, bounds its strings, returns a count
from `move`, and reaches every writer through Loam's receipt envelope. A
description language that cannot say those things cannot describe the
project's own applications.

The canonical Syrup encoder exists and signs handoffs with it. The project has
no notion of interface identity, compatibility, or description.

## The decision

The vocabulary is a strict subset of Preserves Schema's value forms plus an
interface layer:

- Value types: `string`, `bytes`, `symbol`, `bool`, `double`, bounded `int`,
  bounded `string` and `bytes` by length, `seq`, `set`, `dict`, `tuple`,
  `option`, a record with named fields, and a sum of records.
- Reference types: `ref` to a named interface, `sturdy` for a durable
  reference, and `mine` for a reference the server must find in its own
  export table. `mine` is a glowcap extension.
- An interface is a namespaced name and a dictionary from method name to
  method. A method is `call` or `tell`, with named parameters, a reply type,
  an open list of error names, an effect of `read` or `mutate`, and a retry
  mode of `safe`, `receipt`, or `none`. The receipt mode is the Loam envelope
  and is a glowcap extension.
- A `ref` parameter accepts a promise for a reference once the Host lifts
  promise arguments, so this vocabulary never forecloses that work.

The fingerprint is SHA-256 over the canonical Syrup encoding of the shape:
method names, parameter types, reply types, error names, effects, and retry
modes, with methods as a dictionary so order is irrelevant. Parameter names
and notes are outside it. It is a cache key.

Compatibility is a function `conforms(actual, expected)` with these rules:
the actual interface may have more methods, each shared method's parameter
types may be wider and its reply type narrower, and error lists are open, so
a client always handles an unknown error. A description that fails to conform
reports the first method and rule that failed. The same function reports a
breaking change between two committed versions.

The module lives under `src/ocapn/interface/`, is sans-io and deterministic
like the rest of the core, and allocates only through a caller's allocator.

## Steps

Each step is one commit with its own test.

1. **Record the decision.** An ADR for the vocabulary, the data form, the
   fingerprint, the compatibility rules, nominal identity, and the two marked
   extensions. Test: `source-check`.
2. **The model and its Syrup codec.** Types for interfaces, methods,
   parameters, and value types. Decode a Syrup value into the model with
   every malformed shape refused by name, and encode a model canonically.
   Test: round trips over a corpus of descriptions, refusal of each
   malformed shape, and a fuzz target seeded from the corpus.
3. **The fingerprint.** Canonical shape encoding and hash, with the annex and
   parameter names excluded. Test: two descriptions that differ only in
   notes or parameter names share a fingerprint, and reordered methods
   share one.
4. **Compatibility.** `conforms` and the breaking-change report. Test: one
   case per rule in both directions, and a recursive pair of interfaces that
   refer to each other.
5. **Validation.** Check Syrup-encoded arguments against a method and a
   Syrup-encoded reply against its reply type, with bounds enforced and
   refusals named. Test: every value type at its empty, boundary, and
   oversize values.
6. **Describe Tasks and Rooms in the data form.** Hand-written descriptions
   for the Tasks board, list, and task, for the Rooms grammar, and for
   Loam's management methods, committed as Syrup text. Test: a check reads
   each description and the owning server's method table and fails when a
   method, bound, effect, or retry mode disagrees. The Rooms table gains an
   emitter that writes its description, and the check compares the two.
7. **Budget and inventory.** Record the module in the architecture layer
   table and the memory ledger for any wire-path cost. Test: `arch-check`
   and `source-check`.

## Parallel work

Steps 1 through 5 are one lane, since each builds on the model's types. Step
6 can start after step 2 in a second lane and finishes after step 5. One
owner holds the ADR and the module's public surface.

## Questions for you

- The namespace scheme for interface names, as in the parent plan.
- Whether integers default to a bounded type and a bignum is written
  explicitly. The plan says yes.

## Where the code is

| Concern | Where |
| --- | --- |
| New module | `src/ocapn/interface/` |
| Canonical Syrup | `src/ocapn/codec/syrup/canonical.zig` |
| Rooms grammar table | `tools/gen/rooms_protocol.zig` |
| Tasks server method table | `apps/tasks/zig/board.zig` |
| Loam management vocabulary | `src/loam/access/hosting/vocabulary.zig` |
| Layer table | `build.zig`, [`docs/architecture.md`](../architecture.md) |
| Fuzz corpus seeding | `test/support/corpus_seeds.zig` |

Gates: `zig build test`, `zig build arch-check`, `zig build source-check`.
