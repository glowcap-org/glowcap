# The interface language and generators

Status: active plan, waiting for maintainer review before work starts.
Phase two of [interface definitions](interface-definitions.md). It starts
after [the interface model](interface-model.md) lands. Delete this plan when
its steps land.

## What this is for

With the model in place, this phase gives people a way to write an interface
and every language a way to use one. A developer writes `tasks.interface` in
a small text language, runs one command, and gets a client and a server
scaffold in the language they work in. The hand-built Tasks clients in five
languages are deleted, the Rooms grammar table becomes an interface file, and
the typed sharing and management methods that Rooms wrote for itself come
from Loam's interface file for everyone.

## Where things stand

The model reads and writes the data form and validates calls, but only from
Zig. Writing the data form by hand means positional records in angle
brackets, which is how nobody writes a Protocol Buffers descriptor either.
The Rooms emitters exist for five languages and know nothing about the model.

## The decision

The text language is its own small grammar whose meaning is the data form it
compiles to. A method reads `name(args) -> reply`, `tell` marks a one-way
message, `mutate` marks a write, `!` lists error names, `mine` marks an
export-checked argument, and a `///` line above a method is a human note
that goes to the annex. The parser and printer live in the model module, and
the round trip from text to data to text is the language's specification.

An optional archive, `libglowcap_interface`, exposes the module through the
C ABI: load from Syrup or text, emit either, fingerprint, conforms, validate
call, validate reply, and a builder. Generated code in every language
validates through it, so the rules exist once.

Generated code has one shape in every language. A client is a proxy with one
method per call that encodes, sends, and decodes. Each interface gets a
resolved proxy and a promise proxy with the same methods, so a call on a
promised reply pipelines in one round trip. A reference in a reply is an
owned import released by the language's disposal idiom. Each method's errors
become an enumeration plus `unknown` and `transport`.

A server scaffold decodes and validates arguments, performs the `mine`
export check, calls the implementation, encodes the reply, and performs the
receipt envelope for `receipt` methods. The Zig path is a generated source
file like the others.

## Steps

1. **Record the decision.** An ADR for the text grammar, the ABI surface, and
   the generated-code shape, including pipelining proxies, ownership, and
   error enumerations. Test: `source-check`.
2. **The text language.** Parser and printer in the model module, sharing
   Syrup's literal syntax. Test: round trips over the Tasks, Rooms, and Loam
   descriptions from phase one, every grammar error named with its line,
   and a fuzz target.
3. **The archive.** `libglowcap_interface` with its generated header and
   binding tables through the existing `gen-*` steps. Test: a C program loads
   a description, validates a good and a bad call, and fingerprints it.
4. **The command.** `glowcap interface check`, `fmt`, and `gen` for one
   language, Zig, generating the client and server scaffold. Test: the Tasks
   Zig server runs on its scaffold with its hand-written dispatch deleted,
   and the Zig client calls it over an existing Host.
5. **Rust, then TypeScript, Python, and Racket.** One commit per language,
   each extending the Rooms emitter for that language. Test per language: the
   Tasks client passes the lifecycle over loopback, a wrong local call fails
   to compile or import, a malformed reply is refused before application
   code, and a reference in a reply is released by the idiom.
6. **Delete the hand-built Tasks clients.** One commit per language, each
   replacing a hand-built client with the generated one and deleting the
   old. Test: the Tasks app tests and the demo.
7. **Rooms onto the form.** `rooms.interface` replaces the grammar table, the
   emitters read the model, and the table path is deleted. Test: the
   generated protocol check and the Rooms server, peer, and client tests.
8. **Loam management for everyone.** `loam-control.interface` describes
   sharing, inspection, pause, resume, revoke, inventory, and attenuation.
   The Rooms Rust control client becomes a thin wrapper over the generated
   client or is deleted, and its callers move. Test: the existing Rooms
   prepared-control and browser request tests pass through the generated
   client, and Tasks shares a list, pauses it, and revokes it from Python.
9. **Documentation and inventory.** A guide for writing an interface, the
   binding scope, the shipped inventory, and the known limitations. Test:
   `source-check` and the examples build.

## Parallel work

Steps 1 through 4 are one lane. After step 4, step 5 splits by language into
up to three lanes, and step 6 follows each language in its lane. Steps 7 and
8 run after step 5 in two lanes that touch different applications. One
integration owner holds the ADR, the archive, the command, and every
generated file.

## Questions for you

- Whether the human-note annex is emitted at all in this phase, or the `///`
  lines are parsed and dropped until phase three decides who may see them.

## Where the code is

| Concern | Where |
| --- | --- |
| Model module | `src/ocapn/interface/` |
| New archive | `src/c_abi/interface/`, `tools/gen/header/` |
| Rooms emitters | `tools/gen/rooms_protocol/{zig,rust,ts,python,racket}.zig` |
| Tasks clients and server | `apps/tasks/` |
| Rooms grammar consumers | `apps/rooms/lib/protocol.ts`, `apps/rooms/clients/`, `apps/rooms/rust/` |
| Rooms control client | `apps/rooms/rust/glowcap/src/client/access.rs` |
| Loam management encoding | `src/loam/access/hosting/{vocabulary,request,control_request}.zig` |
| CLI | `cli/` |

| Steps | Gate |
| --- | --- |
| 1, 9 | `source-check` |
| 2 | `test` |
| 3 | the generated header and layout checks, then `check` |
| 4 | `cli-test`, `tasks-app-test` |
| 5, 6 | `runtime-check` |
| 7 | `gen-rooms-protocol-check`, `rooms-rust-test`, `rooms-server-test` |
| 8 | `rooms-rust-test`, `rooms-browser-test` |
