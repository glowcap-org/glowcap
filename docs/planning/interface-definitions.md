# Interface definitions

Status: active plan, waiting for maintainer review before work starts.
Delete this plan when its three phases have landed and their plans are gone.

## What this is for

An application that talks to an object over CapTP knows the object's methods
by reading the server's source. It picks the method name, lays out the
arguments in order, decodes the reply, and checks the reply's shape itself.
Tasks does this in Python, TypeScript, Racket, Rust, and Zig, and each copy
is written by hand. Rooms built a careful Rust client with validated replies
and typed sharing, and that client lives in Rooms, so no other application
can use it. A misspelled method or a swapped argument is found by the server
at runtime, or not at all.

This work gives an interface one written form. From that form every language
gets a client that encodes calls and checks replies, and a server scaffold
that checks arguments before the implementation runs. An object may answer
one question, "what are you", with the same form, so a program or an agent
handed a reference can learn what it does without reading anyone's source.

The wire does not change. A Goblins peer calls the same methods by symbol
exactly as before, and an object that answers no question about itself works
with every generated client.

## Where things stand

glowcap speaks OCapN over Syrup and Cap'n Proto. OCapN has no schema and no
introspection, by design, and the group's minutes record that a schema does
not belong in the protocol. E and Endo, the two CapTP implementations before
this one, each grew an optional description layer above the protocol.

Rooms has a generator in the tree. One Zig table declares its wire grammar
with a small vocabulary of value types, and seven emitters write the Zig,
Rust, TypeScript, Python, and Racket projections with a staleness check. It
is scoped to Rooms and it is the nearest thing to the facility this plan
builds.

Loam's managed access layer exposes sharing, inspection, pause, resume, and
revoke as methods on hosted resources, with `describe-access` and
`describe-control` for the standing of a grant. Those are the methods the
Rooms client types by hand.

## The decision

The description of an interface is a Syrup value. It uses a fixed set of
record forms and ordinary Syrup types, so every binding already parses it,
the wire can carry it unchanged, and the canonical Syrup encoding the project
already uses for signatures gives it a fingerprint.

One Zig module owns that vocabulary and every rule about it: reading and
writing the data form, reading and writing a text form for people, the
fingerprint, the compatibility check between two descriptions, and the
validation of a call's arguments and reply against a description. A C ABI
exposes the module, so generated code in every language validates through
one implementation and no binding restates a rule.

People write interfaces in a small text language that compiles to the data
form, in the relationship Preserves Schema has to Preserves. The text form is
its own grammar, not a Syrup dialect, and it borrows Syrup's literal syntax
for names, numbers, and strings.

Identity is a namespaced name the author chooses once. The fingerprint is a
cache key, never the identity. Compatibility is a stated check: methods may be
added, argument types may widen, reply types may narrow, error sets stay open,
and a breaking change is a new name.

An object may answer one reserved, namespaced method with its description.
The object itself dispatches it, so a revoked or attenuated reference answers
for what it exposes and nothing else. The method is optional, bounded, and
conditional on a known fingerprint. Human notes travel in a separate bounded
annex, outside the fingerprint, and never reach a language model unless a
person approved that source.

Generated code is the one way every language consumes the form in this plan.
Runtime-built classes for the dynamic languages and declarations written in a
host language that emit the form are both possible on the same module and
ABI, and neither is built here.

### What is glowcap's and what is OCapN's

The core forms express only what OCapN already has: a call is a deliver, a
tell is a deliver-only, a typed reply is a promise, an error list is a break,
a reference is an export, a durable reference is a sturdyref. Two forms are
glowcap extensions and are marked as such: the export check that refuses a
reference the server did not issue, and the Loam receipt envelope that wraps
a mutating call. The reserved method and the error-name convention are
proposed to the OCapN group as optional conventions. Nothing here is required
of a peer.

## Phases

Each phase is its own plan with its own steps, and each commits to one
design decision while leaving the next open.

1. [The interface model](interface-model.md) commits to the vocabulary and
   the data form: the Zig module, the fingerprint, the compatibility check,
   and validation. Tasks and Rooms are described in the data form and checked
   against their servers. No text language, no C ABI, no reserved method.
2. [The interface language and generators](interface-language.md) commits to
   the text form and the shape of generated code: the C ABI archive, the
   `glowcap interface` command, clients and server scaffolds in five
   languages, and the migration of Tasks, the Rooms grammar, and Loam's
   management methods onto the form. The hand-built clients are deleted.
3. [Interface discovery](interface-discovery.md) commits to the runtime
   convention: the reserved method, its bounds and conditional form, the
   forwarder rule, the agent front behavior, the interop proof against a
   plain Goblins object, and the upstream proposal.

## Parallel work

The phases are sequential. Inside each phase its plan says what runs beside
what. One integration owner owns this plan, the roadmap item, and the
decision records across all three phases.

## Questions for you

- The namespace scheme for interface names: a project prefix such as
  `tasks/list`, reverse DNS, or random identifiers with names beside them.
- Whether the reserved method and the error-name convention go to the OCapN
  group before phase 3 starts, or after glowcap has run them.
- Whether the human-note annex is in scope at all before an agent front
  exists that can show it to a person and pin it.
- Whether the Loam receipt envelope stays a described extension or hosted
  verbs become direct methods later. The plan keeps the envelope.

## Where the code is

| Concern | Where |
| --- | --- |
| The Rooms grammar table and its emitters | `tools/gen/rooms_protocol.zig`, `tools/gen/rooms_protocol/` |
| Canonical Syrup encoding used for signatures | `src/ocapn/codec/syrup/canonical.zig`, ADR-0039 |
| Tasks server and hand-built clients | `apps/tasks/zig/board.zig`, `apps/tasks/{python,deno,racket,rust}/` |
| Rooms typed management client | `apps/rooms/rust/glowcap/src/client/access.rs` |
| Loam management methods and request envelope | `src/loam/access/hosting/vocabulary.zig`, `request.zig`, `control_request.zig` |
| Managed access model | [`docs/loam/access-api.md`](../loam/access-api.md), ADR-0046, ADR-0052, ADR-0056 |
| OCapN draft and minutes | `conformance/ocapn-spec/upstream/` |
