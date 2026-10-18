# Learn glowcap by example

Start with chapter 01. It is one short Zig program: one peer publishes an
object, and another fetches it and calls it over encrypted TCP. Chapter 02
adds a third peer and an introduction. The later chapters stay in one process
to show actors, the protocol engine, and storage up close.

Every chapter builds and runs with one command:

```sh
zig build examples
```

## Complete applications

For whole programs, see [`apps/`](../apps/README.md). It
lists each application, often written in several languages, with the command
that runs it. The biggest is Rooms, a chat app over encrypted iroh.
`zig build rooms-web` serves it and prints the address to open in your browser.

## Zig chapters

| Chapter | What you will learn |
| --- | --- |
| [01: connect and serve](zig/01_connect_and_serve.zig) | Listen, publish a greeter, connect, fetch it by name, and call it through `driver.Session`. |
| [02: introduce and redeem](zig/02_introduce_and_redeem.zig) | Let one peer introduce two others, then make the direct call without keeping the introducer in the path. |
| [03: actor far send](zig/03_actor_far_send.zig) | Export an actor, send to it from another peer, and settle the promise it returns (Goblins calls it a vow). |
| [04: look up by name](zig/04_look_up_by_name.zig) | See how `fetch("name")` uses the bootstrap object and a swiss number underneath. |
| [05: call a remote method](zig/05_call_a_remote_method.zig) | Drive the raw engine one step at a time: exports, imports, delivery, and how promises resolve. |
| [06: pipeline and attenuate](zig/06_pipeline_and_attenuate.zig) | Send dependent calls before the first answer arrives, then restrict the returned capability to selected methods. |
| [07: durable card](zig/07_durable_card.zig) | Keep a sleepy actor in Loam's SQLite store, restart everything, and find its state still there. |

The source of each chapter begins with a longer explanation of the scenario.
Copy chapter 01 to start an application. Read chapter 05 if your program runs
the event loop and the protocol peer itself.

For the command line instead of Zig, use the [CLI guide](../docs/cli.md).

## Small mechanics

- [`readme_quick_start.zig`](zig/readme_quick_start.zig) compiles the
  sealed `noise-tcp` client shown in the root README and supplies the greeter
  it calls.
- [`many_sessions_one_loop.zig`](zig/many_sessions_one_loop.zig) repeats
  chapter 02's introduction for many clients at once, served by one
  directory `Server` thread.
- [`frame_view.zig`](zig/frame_view.zig) shows an owned frame becoming a
  borrowed view.

## C examples

- [`host_embedder_pump.c`](c/host_embedder_pump.c) drives `GlowcapHost`, the
  C API for CapTP applications, through a whole conversation in memory:
  feeding bytes in, draining frames out, a refusal, and breaking far
  promises. The language bindings do the same thing underneath.
- [`frame_view.c`](c/frame_view.c) shows a borrowed `GlowcapFrame` over caller
  bytes. Owned frames come from `take_outbound` in the host example.

The [C guide](../docs/consuming-from-c.md) explains which API and libraries to
choose before you adapt one of these programs.

## Related directories

| Path | Role |
| --- | --- |
| [`site/examples/`](../site/examples/README.md) | Per-transport first-call tabs on Start building, the binding pages, and the transport pages |
| [`bindings/proofs/`](../bindings/proofs/README.md) | Cross-language binding proofs. The Rust clients live where Cargo expects them, under `bindings/rust/examples/` |
