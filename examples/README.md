# Learn pancake by example

Start with chapter 01 and continue in number order. The first two chapters use
the application APIs over TCP. Later chapters open the layers underneath.

Every example is a runnable build target:

```sh
zig build examples
```

## Zig chapters

| Chapter | What you will learn |
| --- | --- |
| [01: connect and serve](zig/01_connect_and_serve.zig) | Listen, publish a greeter, connect, fetch it by name, and call it through `driver.Session`. Start here. |
| [02: introduce and redeem](zig/02_introduce_and_redeem.zig) | Let one peer introduce two others, then make the direct call without keeping the introducer in the path. |
| [03: actor far send](zig/03_actor_far_send.zig) | Export an actor, send to it from another peer, and settle the returned vow. |
| [04: look up by name](zig/04_look_up_by_name.zig) | See how `fetch("name")` uses the bootstrap object and a swiss number underneath. |
| [05: call a remote method](zig/05_call_a_remote_method.zig) | Drive the raw engine one step at a time, including exports, imports, delivery, and settlement. |
| [06: pipeline and attenuate](zig/06_pipeline_and_attenuate.zig) | Send dependent calls before the first answer arrives, then restrict the returned capability to selected methods. |

The source of each chapter begins with a longer explanation of the scenario.
Chapter 01 is the best template for an application. Chapter 05 is for an
embedder that intends to own the event loop and protocol peer directly.

For the command line instead of Zig, use the [CLI guide](../docs/cli.md).

## Complete applications

These programs use the same small API from several languages:

| Application | What it demonstrates | Run it |
| --- | --- | --- |
| [Rooms](../apps/rooms/) | A chat server hands clients room and inbox capabilities. Zig, Rust, TypeScript, Python, and Racket clients exchange broadcasts. | `zig build demo-rooms` |
| [Tasks](../apps/tasks/) | A shared task board combines request-response calls, structured values, and change notifications. | `zig build demo-tasks` |
| [Tools](../apps/tools/) | A coordinator grants agents tool capabilities, narrows them to read-only use, and revokes them. | `zig build demo-tools` |
| [Accountability](../apps/accountability-on-pancake/) | Signed identity and an audit log sit above an ordinary capability call. | `zig build accountability` |

The demos start their own server on an available port. Pass `-Dport=9099` to
choose one. Rooms, tasks, and tools also accept `-Dattach=true` when you want
their clients to join a server you started separately.

Missing optional language runtimes are reported as skipped. Each application's
README has its standalone commands.

## Small mechanics

- [`readme_quick_start.zig`](zig/readme_quick_start.zig) compiles the exact
  client shown in the root README and supplies the greeter it calls.
- [`connect_explicit_buffers.zig`](zig/connect_explicit_buffers.zig) repeats
  chapter 01 with caller-owned buffers and the lower-level blocking API.
- [`frame_view.zig`](zig/frame_view.zig) shows an owned frame becoming a
  borrowed view.

## C examples

- [`host_embedder_pump.c`](c/host_embedder_pump.c) drives the sole C CapTP
  application surface, `PancakeHost`, through a complete in-memory conversation:
  feed, drain, refusal, and break-far-vows, as language bindings do.
- [`frame_view.c`](c/frame_view.c) shows a borrowed `PancakeFrame` over caller
  bytes. Owned frames come from `take_outbound` in the host example.

The [C guide](../docs/consuming-from-c.md) explains which API and libraries to
choose before you adapt one of these programs.
